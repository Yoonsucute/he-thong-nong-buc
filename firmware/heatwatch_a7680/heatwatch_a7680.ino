#include <Wire.h>
#include <Adafruit_SHT31.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>
#include <math.h>
#include <TinyGPSPlus.h>

// Existing wiring: ESP32 RX16 <- A7680 TX, ESP32 TX17 -> A7680 RX.
#define SIM_RX 16
#define SIM_TX 17
// ATGM336H TX -> GPS_RX, GND -> GND. Its RX pin can stay disconnected.
constexpr int GPS_RX = 26;
constexpr int GPS_TX = 27;
constexpr unsigned long GPS_BAUD = 9600;
#define SCREEN_WIDTH 128
#define SCREEN_HEIGHT 64
#define OLED_RESET -1
#define OLED_ADDRESS 0x3C

HardwareSerial sim4G(2);
HardwareSerial gpsSerial(1);
TinyGPSPlus gps;
TinyGPSCustom gpFixQuality(gps, "GPGGA", 6);
TinyGPSCustom gnFixQuality(gps, "GNGGA", 6);
Adafruit_SHT31 sht31;
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, OLED_RESET);

const char* DEVICE_ID = "ESP32_01";
const char* MQTT_HOST = "broker.emqx.io";
const int MQTT_PORT = 1883;
const char* MQTT_CLIENT_ID = "HeatIndexESP32_Tien01";
const char* MQTT_TOPIC = "iot/heatindex/tien01/data";

// Empty means preserve the APN already configured on the module/SIM.
// Fill in the carrier's APN only if its existing PDP context is not usable.
const char* MOBILE_APN = "";
const int PDP_CID = 1;

const unsigned long SENSOR_INTERVAL = 2000;
const unsigned long NETWORK_INTERVAL = 30000;
const unsigned long MQTT_INTERVAL = 10000;
const unsigned long MQTT_RETRY_INTERVAL = 30000;
const unsigned long GPS_MAX_AGE = 5000;

bool mqttOK = false;
bool shtOK = false;
bool oledOK = false;
bool simOK = false;
bool networkOK = false;
bool sensorHasReading = false;
bool gpsHasFix = false;
unsigned int satellites = 0;
bool publishPending = true;
float temperature = 0;
float humidity = 0;
float heatIndex = 0;
double latitude = 0;
double longitude = 0;
unsigned long locationMillis = 0;
unsigned long lastSensorRead = 0;
unsigned long lastNetworkCheck = 0;
unsigned long lastMqttPublish = 0;
unsigned long lastMqttRetry = 0;
String modemLine;
unsigned long mqttLossCount = 0;

struct ModemReply {
  String text;
  String expectedLine;
  bool ok = false;
  bool error = false;
  bool prompt = false;
  bool found = false;
};

void serviceSensors();
void updateOLED();
void readSensor();

// Dong bo cong thuc Heat Index (Steadman + Rothfusz) va 3 muc canh bao
// (<32°C: AN TOAN, 32-38°C: CANH BAO NONG, >=38°C: CUC KY NGUY HIEM)
// khop hoan toan voi Backend Flask, Website va Ung dung Flutter.
float calculateHeatIndex(float tempC, float rh) {
  float T = tempC * 1.8f + 32.0f;
  float hi_f = 0.5f * (T + 61.0f + ((T - 68.0f) * 1.2f) + (rh * 0.094f));
  if (hi_f >= 80.0f) {
    hi_f = -42.379f + 2.04901523f * T + 10.14333127f * rh
        - 0.22475541f * T * rh - 0.00683783f * T * T
        - 0.05481717f * rh * rh + 0.00122874f * T * T * rh
        + 0.00085282f * T * rh * rh - 0.00000199f * T * T * rh * rh;
  }
  return roundf(((hi_f - 32.0f) / 1.8f) * 10.0f) / 10.0f;
}

String getWarning(float hi) {
  if (hi >= 38.0f) return "CUC KY NGUY HIEM";
  if (hi >= 32.0f) return "CANH BAO NONG";
  return "AN TOAN";
}

bool gpsFixUsable() {
  return gpsHasFix && millis() - locationMillis < GPS_MAX_AGE;
}

void serviceGPS() {
  while (gpsSerial.available()) {
    // TinyGPS++ commits fields only after the complete sentence checksum passes.
    if (!gps.encode((char)gpsSerial.read())) continue;
    TinyGPSCustom* quality = nullptr;
    if (gpFixQuality.isUpdated()) quality = &gpFixQuality;
    if (gnFixQuality.isUpdated()) quality = &gnFixQuality;
    if (quality == nullptr) continue;

    const char* fixQuality = quality->value();
    satellites = gps.satellites.value();
    const bool measuredFix = fixQuality[0] >= '1' && fixQuality[0] <= '5' &&
        fixQuality[1] == '\0';
    const double lat = gps.location.lat();
    const double lon = gps.location.lng();
    if (!measuredFix || !satellites || !gps.location.isValid() ||
        !isfinite(lat) || !isfinite(lon) || fabs(lat) > 90 || fabs(lon) > 180 ||
        (lat == 0 && lon == 0)) {
      gpsHasFix = false;
      continue;
    }
    latitude = lat;
    longitude = lon;
    locationMillis = millis();
    gpsHasFix = true;
  }
  if (gpsHasFix && !gpsFixUsable()) {
    gpsHasFix = false;
    satellites = 0;
  }
}

void processUnsolicited(const String& line) {
  // Preserve connection-loss notifications even when waiting for another AT
  // response. Never empty the UART by discarding unread bytes.
  if (line.startsWith("+CMQTTCONNLOST:") ||
      line.startsWith("+CMQTTNONET")) {
    mqttOK = false;
    mqttLossCount++;
    Serial.println("MQTT: mat ket noi, se thu lai.");
  }
}

void readModemBytes(ModemReply* reply = nullptr,
                    const char* expectedPrefix = nullptr) {
  while (sim4G.available()) {
    char c = (char)sim4G.read();
    Serial.write(c);
    if (reply != nullptr) {
      if (reply->text.length() < 4096) reply->text += c;
      if (c == '>') {
        reply->prompt = true;
        modemLine = "";
        continue;
      }
    }
    if (c == '\r') continue;
    if (c == '\n') {
      String line = modemLine;
      modemLine = "";
      line.trim();
      if (line.isEmpty()) continue;
      processUnsolicited(line);
      if (reply != nullptr) {
        if (line == "OK") reply->ok = true;
        if (line == "ERROR" || line.startsWith("+CME ERROR:") ||
            line.startsWith("+CMS ERROR:")) reply->error = true;
        if (expectedPrefix != nullptr && line.startsWith(expectedPrefix)) {
          reply->found = true;
          reply->expectedLine = line;
        }
      }
    } else if (modemLine.length() < 1024) {
      modemLine += c;
    } else {
      // Bounded buffer; consume the rest of an oversized line.
      modemLine = "";
    }
  }
}

ModemReply waitReply(unsigned long timeout, const char* expectedPrefix = nullptr,
                     bool waitForPrompt = false) {
  ModemReply reply;
  unsigned long start = millis();
  while (millis() - start < timeout) {
    readModemBytes(&reply, expectedPrefix);
    if (reply.error || (waitForPrompt && reply.prompt) ||
        (expectedPrefix != nullptr && reply.found) ||
        (!waitForPrompt && expectedPrefix == nullptr && reply.ok)) break;
    // Keep reading GPS and the sensor while the modem waits for an AT reply.
    serviceSensors();
    delay(1);
  }
  return reply;
}

ModemReply sendAT(const String& command, unsigned long timeout = 2000,
                   const char* expectedPrefix = nullptr) {
  readModemBytes();
  Serial.print("\n>> ");
  Serial.println(command);
  sim4G.print(command);
  sim4G.print("\r\n");
  return waitReply(timeout, expectedPrefix);
}

bool sendATData(const String& command, const char* data,
                 unsigned long timeout = 5000) {
  readModemBytes();
  Serial.print("\n>> ");
  Serial.println(command);
  sim4G.print(command);
  sim4G.print("\r\n");
  ModemReply prompt = waitReply(timeout, nullptr, true);
  if (!prompt.prompt || prompt.error) {
    Serial.println("Khong nhan duoc prompt '>'.");
    return false;
  }
  sim4G.write((const uint8_t*)data, strlen(data));
  ModemReply result = waitReply(timeout);
  return result.ok && !result.error;
}

bool oneCodeSuccess(const ModemReply& reply, const char* prefix) {
  if (reply.error || !reply.found) return false;
  String number = reply.expectedLine.substring(strlen(prefix));
  number.trim();
  return number == "0";
}

bool clientCodeSuccess(const ModemReply& reply, const char* prefix) {
  if (reply.error || !reply.found) return false;
  const char* position = reply.expectedLine.c_str() + strlen(prefix);
  int client = -1, result = -1;
  char trailing = 0;
  int fields = sscanf(position, " %d , %d %c", &client, &result, &trailing);
  return fields == 2 && client == 0 && result == 0;
}

bool registeredNetwork(const String& response) {
  int start = response.indexOf("+CEREG:");
  if (start < 0) return false;
  int end = response.indexOf('\n', start);
  String line = response.substring(start + 7, end < 0 ? response.length() : end);
  int reportMode = -1, status = -1;
  if (sscanf(line.c_str(), " %d , %d", &reportMode, &status) == 2) {
    return status == 1 || status == 5;
  }
  return false;
}

bool pdpActive(const String& response) {
  int offset = 0;
  while ((offset = response.indexOf("+CGACT:", offset)) >= 0) {
    int cid = -1, active = -1;
    if (sscanf(response.c_str() + offset + 7, " %d , %d", &cid, &active) == 2 &&
        cid == PDP_CID && active == 1) return true;
    offset += 7;
  }
  return false;
}

void check4G() {
  Serial.println("\n===== KIEM TRA A7680C =====");
  ModemReply reply = sendAT("AT");
  simOK = reply.ok && !reply.error;
  if (!simOK) {
    networkOK = false;
    mqttOK = false;
    return;
  }
  reply = sendAT("AT+CPIN?");
  bool simReady = reply.text.indexOf("+CPIN: READY") >= 0;
  sendAT("AT+CSQ");
  reply = sendAT("AT+CEREG?");
  networkOK = simReady && !reply.error && registeredNetwork(reply.text);
  if (!networkOK) mqttOK = false;
  Serial.println(networkOK ? "LTE: DA DANG KY MANG" : "LTE: CHUA DANG KY MANG");
}

bool ensurePdp() {
  if (!simOK || !networkOK) return false;
  ModemReply reply = sendAT("AT+CGACT?");
  if (pdpActive(reply.text)) return true;
  Serial.println("PDP chua hoat dong; thu kich hoat context da cau hinh.");
  reply = sendAT(String("AT+CGACT=1,") + PDP_CID, 15000);
  if (!reply.ok || reply.error) return false;
  reply = sendAT("AT+CGACT?");
  return pdpActive(reply.text);
}

void resetMQTT() {
  mqttOK = false;
  if (!simOK) return;
  sendAT("AT+CMQTTDISC=0,10", 12000, "+CMQTTDISC:");
  sendAT("AT+CMQTTREL=0", 3000);
  sendAT("AT+CMQTTSTOP", 8000, "+CMQTTSTOP:");
}

bool connectMQTT() {
  mqttOK = false;
  if (!networkOK || !ensurePdp()) return false;
  ModemReply reply = sendAT("AT+CMQTTSTART", 10000, "+CMQTTSTART:");
  if (!oneCodeSuccess(reply, "+CMQTTSTART:")) return false;
  String command = String("AT+CMQTTACCQ=0,\"") + MQTT_CLIENT_ID + "\",0";
  reply = sendAT(command, 3000);
  if (!reply.ok || reply.error) return false;
  command = String("AT+CMQTTCONNECT=0,\"tcp://") + MQTT_HOST + ":" +
      MQTT_PORT + "\",60,1";
  unsigned long lossesBeforeConnect = mqttLossCount;
  reply = sendAT(command, 15000, "+CMQTTCONNECT:");
  mqttOK = clientCodeSuccess(reply, "+CMQTTCONNECT:") &&
      mqttLossCount == lossesBeforeConnect;
  Serial.println(mqttOK ? "MQTT: DA KET NOI BROKER" : "MQTT: KET NOI THAT BAI");
  return mqttOK;
}

String jsonString(const char* value) {
  String output = "\"";
  for (; *value; value++) {
    if (*value == '\\' || *value == '"') output += '\\';
    if ((unsigned char)*value >= 32) output += *value;
  }
  return output + '"';
}

bool publishMQTT() {
  // A first fix must not wait for a working SHT31. Location-only messages are
  // accepted by the backend without manufacturing a sensor reading.
  if (!mqttOK) return false;
  String payload = "{\"device_id\":" + jsonString(DEVICE_ID);
  if (sensorHasReading) {
    payload += ",\"temperature\":" + String(temperature, 1);
    payload += ",\"humidity\":" + String(humidity, 1);
    payload += ",\"heat_index\":" + String(heatIndex, 1);
    payload += ",\"warning\":" + jsonString(getWarning(heatIndex).c_str());
  }
  const bool gpsValid = gpsFixUsable();
  payload += ",\"lte\":\"" + String(networkOK ? "ONLINE" : "OFFLINE") + "\"";
  payload += String(",\"gps_valid\":") + (gpsValid ? "true" : "false");
  payload += ",\"satellites\":" + String(satellites);
  payload += ",\"location_source\":\"gps\"";
  if (gpsValid) {
    payload += ",\"latitude\":" + String(latitude, 6);
    payload += ",\"longitude\":" + String(longitude, 6);
    payload += ",\"location_age_s\":" + String((millis() - locationMillis) / 1000);
  } else {
    payload += ",\"latitude\":null,\"longitude\":null";
  }
  payload += "}";
  Serial.println("\n===== MQTT PUBLISH =====");
  Serial.println(payload);
  String command = String("AT+CMQTTTOPIC=0,") + strlen(MQTT_TOPIC);
  if (!sendATData(command, MQTT_TOPIC)) return false;
  command = String("AT+CMQTTPAYLOAD=0,") + payload.length();
  if (!sendATData(command, payload.c_str())) return false;
  ModemReply reply = sendAT("AT+CMQTTPUB=0,1,60", 15000, "+CMQTTPUB:");
  bool success = clientCodeSuccess(reply, "+CMQTTPUB:");
  Serial.println(success ? "MQTT PUBLISH: THANH CONG" : "MQTT PUBLISH: THAT BAI");
  Serial.printf("[%lu ms] MQTT ACK: %s\n", millis(), success ? "OK" : "FAILED");
  return success;
}

void updateOLED() {
  if (!oledOK) return;
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);
  display.setTextSize(1);
  display.setCursor(0, 0);
  display.println("HE THONG NONG BUC");
  display.setCursor(0, 14);
  display.print("T:");
  if (sensorHasReading) display.print(temperature, 1); else display.print("--");
  display.print("C");
  display.setCursor(70, 14);
  display.print("H:");
  if (sensorHasReading) display.print(humidity, 0); else display.print("--");
  display.print("%");
  display.setTextSize(2);
  display.setCursor(0, 27);
  display.print("HI:");
  if (sensorHasReading) display.print(heatIndex, 1); else display.print("--");
  display.setTextSize(1);
  display.setCursor(0, 48);
  display.print(sensorHasReading ? getWarning(heatIndex) : "CHUA CO DU LIEU");
  display.setCursor(0, 56);
  display.print(mqttOK ? "MQ:OK" : "MQ:NO");
  display.setCursor(42, 56);
  display.print(networkOK ? "4G:OK" : "4G:NO");
  display.setCursor(84, 56);
  display.print(gpsFixUsable() ? "GPS:OK" : "GPS:NO");
  display.display();
}

void readSensor() {
  float t = sht31.readTemperature();
  float h = sht31.readHumidity();
  if (!isfinite(t) || !isfinite(h) || h < 0 || h > 100) {
    sensorHasReading = false;
    Serial.println("LOI DOC SHT31: khong gui so 0 thay the.");
    updateOLED();
    return;
  }
  temperature = t;
  humidity = h;
  heatIndex = calculateHeatIndex(t, h);
  sensorHasReading = isfinite(heatIndex);
  Serial.printf("SHT31: T=%.1f C H=%.1f %% HI=%.1f C\n", t, h, heatIndex);
  updateOLED();
}

void serviceSensors() {
  serviceGPS();
  if (shtOK && millis() - lastSensorRead >= SENSOR_INTERVAL) {
    lastSensorRead = millis();
    readSensor();
  }
}

void setup() {
  Serial.begin(115200);
  gpsSerial.begin(GPS_BAUD, SERIAL_8N1, GPS_RX, GPS_TX);
  Serial.println("\nHEATWATCH ESP32 + ATGM336H + A7680C");
  Serial.print("DEVICE_ID: ");
  Serial.println(DEVICE_ID);
  Wire.begin(21, 22);
  shtOK = sht31.begin(0x44);
  oledOK = display.begin(SSD1306_SWITCHCAPVCC, OLED_ADDRESS);
  Serial.println(shtOK ? "SHT31: OK" : "SHT31: KHONG TIM THAY");
  Serial.println(oledOK ? "OLED: OK" : "OLED: KHONG TIM THAY");
  if (shtOK) readSensor();
  updateOLED();
  sim4G.begin(115200, SERIAL_8N1, SIM_RX, SIM_TX);
  Serial.println("Cho A7680C khoi dong...");
  unsigned long bootStart = millis();
  while (millis() - bootStart < 10000) {
    serviceSensors();
    delay(1);
  }
  check4G();
  if (simOK) {
    sendAT("ATE0");
    sendAT("ATI");
    sendAT("AT+CGMR");
    if (strlen(MOBILE_APN) > 0) {
      sendAT(String("AT+CGDCONT=") + PDP_CID + ",\"IP\",\"" + MOBILE_APN + "\"");
    }
  }
  if (networkOK) {
    resetMQTT();
    connectMQTT();
  }
  lastSensorRead = millis();
  lastNetworkCheck = millis();
  lastMqttRetry = millis();
  updateOLED();
}

void loop() {
  readModemBytes();
  serviceSensors();
  if (millis() - lastNetworkCheck >= NETWORK_INTERVAL) {
    lastNetworkCheck = millis();
    check4G();
    updateOLED();
  }
  if (mqttOK && (publishPending || millis() - lastMqttPublish >= MQTT_INTERVAL)) {
    lastMqttPublish = millis();
    if (publishMQTT()) {
      publishPending = false;
    } else {
      resetMQTT();
      lastMqttRetry = millis();
    }
  }
  if (!mqttOK && networkOK && millis() - lastMqttRetry >= MQTT_RETRY_INTERVAL) {
    lastMqttRetry = millis();
    resetMQTT();
    if (connectMQTT()) publishPending = true;
    updateOLED();
  }
  delay(1);
}
