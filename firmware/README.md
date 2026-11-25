# Firmware HeatWatch ESP32 + ATGM336H + A7680C

Tệp nạp: [heatwatch_a7680.ino](heatwatch_a7680/heatwatch_a7680.ino).

## Chân UART và I²C

| Thiết bị | Nối với ESP32 |
| --- | --- |
| ATGM336H TX | GPIO26 (RX UART1, cấu hình tại `GPS_RX`) |
| ATGM336H GND | GND chung |
| A7680C TX | GPIO16 (RX UART2) |
| A7680C RX | GPIO17 (TX UART2) |
| A7680C GND | GND chung |
| SHT31/OLED SDA | GPIO21 |
| SHT31/OLED SCL | GPIO22 |

Đối chiếu GPIO đã đấu trên bo trước khi nạp. Sketch mặc định GPS dùng
9600 baud, 8N1; có thể đổi `GPS_BAUD` nếu module đã cấu hình khác.
GPIO27 dành cho TX UART1 trong cấu hình mặc định. Sketch chỉ đọc GPS nên
có thể để hở RX của module. A7680C dùng 115200 baud, 8N1. Cấp nguồn và dùng
mức tín hiệu UART theo tài liệu của bo module thực tế.

## Mở và biên dịch

Trong Arduino IDE, cài/chọn ESP32 by Espressif Systems và các thư viện:

- Adafruit SHT31 Library
- Adafruit GFX Library
- Adafruit SSD1306
- Adafruit BusIO (phụ thuộc của các thư viện trên)
- TinyGPSPlus

Mở tệp `.ino`, chọn đúng loại bo ESP32 đang dùng và cổng USB. Sketch không cần thêm TinyGSM, PubSubClient hoặc ArduinoJson: MQTT sử dụng bộ lệnh AT sẵn có trên A7680C, giữ cùng broker/topic của chương trình cũ.

`DEVICE_ID` mặc định là `ESP32_01`, trùng thiết bị hiện có trong MySQL. Nếu thêm ESP32 khác, đặt **cả `DEVICE_ID` và `MQTT_CLIENT_ID` riêng** cho mỗi thiết bị; backend và app nhận diện bằng `device_id`.

Biến `MOBILE_APN` để trống nhằm giữ cấu hình APN của module/SIM. Nếu context PDP chưa hoạt động, điền APN đúng của nhà mạng; không chép APN nhà mạng khác hoặc thay đổi IMEI. Context mặc định là `PDP_CID = 1`.

## Dữ liệu MQTT và kiểm tra

- Firmware đọc tọa độ từ bản tin NMEA GGA của ATGM336H, kể cả trong lúc chờ
  lệnh AT của modem. Fix hợp lệ có checksum đúng, chất lượng fix đo được,
  vệ tinh tham gia và tọa độ hợp lệ. Fix hết hiệu lực sau 5 giây thiếu cập nhật.
- Chu kỳ MQTT là 10 giây. Payload có `location_source: "gps"`, `gps_valid`,
  `satellites`, `latitude`, `longitude`. Khi GPS hợp lệ có thêm `location_age_s`.
  Khi GPS chưa có fix, hai tọa độ là `null`. Nếu SHT31 chưa có số đo hợp lệ,
  firmware vẫn gửi trạng thái GPS/LTE và bỏ các trường số đo.
- Flask lưu tọa độ trạm vào MySQL theo `device_id`. Khi GPS mất fix, API
  giữ tọa độ hợp lệ gần nhất cùng thời điểm gốc và báo trạng thái tương ứng.
  Bản tin LBS cũ vẫn tương thích và không ghi đè vị trí GPS đã xác nhận.
- Mở Serial Monitor ở 115200 baud để xem payload thực tế và ACK MQTT.
  OLED hiển thị `GPS:OK` khi có fix hợp lệ, `GPS:NO` khi chưa có fix.
  Kiểm tra cùng `device_id` trên `/api/devices` và hai bản đồ.
