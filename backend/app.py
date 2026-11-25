"""REST API dùng chung cho website quản trị và ứng dụng Flutter."""
from contextlib import contextmanager
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import json
import math
import os
import queue
import re
import threading
from pathlib import Path
from flask import Flask, Response, jsonify, render_template, request, stream_with_context
from flask_cors import CORS
import pymysql
try:
    from .admin_auth import admin_required, init_admin_auth
    from .rain_routes import init_rain_routes
    from .weather import weather_api
except ImportError:
    from admin_auth import admin_required, init_admin_auth
    from rain_routes import init_rain_routes
    from weather import weather_api
try:
    from .ml.ml_service import calculate_heat_index, run_lstm_forecast, ForecastUnavailable
except ImportError:
    from ml.ml_service import calculate_heat_index, run_lstm_forecast, ForecastUnavailable

app = Flask(__name__, instance_path=str(Path(__file__).resolve().parent / "instance"))
init_admin_auth(app)
app.register_blueprint(weather_api)
app.logger.setLevel(os.getenv("LOG_LEVEL", "INFO"))
app.json.ensure_ascii = False
CORS(app, resources={r"/api/*": {"origins": os.getenv("CORS_ORIGINS", "*").split(",")}})
LOCAL_TZ = timezone(timedelta(hours=7))
DB_CONFIG = {
    # Local Laragon uses 3307; the separate MySQL 8.0 service keeps 3306.
    "host": os.getenv("DB_HOST", "127.0.0.1"), "port": int(os.getenv("DB_PORT", "3307")),
    "user": os.getenv("DB_USER", "root"), "password": os.getenv("DB_PASSWORD", "root"),
    "database": os.getenv("DB_NAME", "iot_db"), "charset": "utf8mb4",
    "cursorclass": pymysql.cursors.DictCursor, "connect_timeout": 5, "read_timeout": 10, "write_timeout": 10,
}
MQTT_BROKER = os.getenv("MQTT_BROKER", "broker.emqx.io")
MQTT_PORT = int(os.getenv("MQTT_PORT", "1883"))
MQTT_TOPIC = os.getenv("MQTT_TOPIC", "iot/heatindex/tien01/data")
ONLINE_SECONDS = int(os.getenv("DEVICE_ONLINE_SECONDS", "120"))
LOCATION_MAX_AGE_SECONDS = 600
LOCATION_SOURCES = ("manual", "lbs", "gnss", "gps", "unknown")
GPS_SOURCES = ("gps", "atgm336h", "gps_atgm336h", "atgm336h_gps")
GPS_METADATA = {"gps_valid": "BOOLEAN NULL", "satellites": "TINYINT UNSIGNED NULL"}
_schema_ready = False
_schema_lock = threading.Lock()
_alert_subscribers = set()
_alert_lock = threading.Lock()
mqtt_client = None


def publish_realtime_alert(payload):
    """Đẩy cảnh báo vượt ngưỡng tức thời tới tất cả client đang mở SSE."""
    with _alert_lock:
        subscribers = list(_alert_subscribers)
    for subscriber in subscribers:
        try:
            subscriber.put_nowait(payload)
        except queue.Full:
            try:
                subscriber.get_nowait()
            except queue.Empty:
                pass
            try:
                subscriber.put_nowait(payload)
            except queue.Full:
                pass

class ApiError(Exception):
    def __init__(self, message, status=400, code="invalid_request"):
        self.message, self.status, self.code = message, status, code

@app.errorhandler(ApiError)
def api_error(error):
    return jsonify(error=error.message, code=error.code), error.status

@app.errorhandler(pymysql.MySQLError)
def database_error(error):
    app.logger.error("MySQL unavailable: %s", type(error).__name__)
    return jsonify(error="Không kết nối được MySQL. Kiểm tra máy chủ và cấu hình DB.", code="database_unavailable"), 503

def ensure_schema(connection):
    """Thêm bảng thiết bị và nhập thiết bị cũ, không xóa dữ liệu sensor_logs."""
    global _schema_ready
    if _schema_ready:
        return
    with _schema_lock:
        if _schema_ready:
            return
        with connection.cursor() as cursor:
            cursor.execute("""CREATE TABLE IF NOT EXISTS sensor_logs (
                id BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY, device_id VARCHAR(100) NOT NULL,
                temperature DOUBLE NOT NULL, humidity DOUBLE NOT NULL, heat_index DOUBLE NULL,
                latitude DOUBLE NULL, longitude DOUBLE NULL,
                location_source VARCHAR(16) NULL DEFAULT 'unknown', location_updated_at DATETIME NULL,
                gps_valid BOOLEAN NULL, satellites TINYINT UNSIGNED NULL,
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                INDEX idx_sensor_device_time (device_id, created_at, id)) CHARACTER SET utf8mb4""")
            cursor.execute("""CREATE TABLE IF NOT EXISTS devices (
                device_id VARCHAR(100) PRIMARY KEY, name VARCHAR(150) NOT NULL,
                latitude DOUBLE NULL, longitude DOUBLE NULL, enabled BOOLEAN NOT NULL DEFAULT TRUE,
                location_source VARCHAR(16) NULL DEFAULT 'unknown', location_updated_at DATETIME NULL,
                location_pending BOOLEAN NOT NULL DEFAULT TRUE,
                gps_valid BOOLEAN NULL, satellites TINYINT UNSIGNED NULL, gps_reported_at DATETIME NULL,
                created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP,
                updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
                ) CHARACTER SET utf8mb4""")
            # Add only missing columns, including on installations with old tables.
            cursor.execute("SHOW COLUMNS FROM devices LIKE 'location_pending'")
            if not cursor.fetchone():
                cursor.execute("ALTER TABLE devices ADD COLUMN location_pending BOOLEAN NOT NULL DEFAULT TRUE")
            # Old coordinates stay unknown/NULL until a real fix or manual edit.
            for table in ("devices", "sensor_logs"):
                cursor.execute(f"SHOW COLUMNS FROM {table}")
                fields = {column["Field"] for column in cursor.fetchall()}
                if "location_source" not in fields:
                    cursor.execute(f"ALTER TABLE {table} ADD COLUMN location_source VARCHAR(16) NULL DEFAULT 'unknown'")
                if "location_updated_at" not in fields:
                    cursor.execute(f"ALTER TABLE {table} ADD COLUMN location_updated_at DATETIME NULL")
                metadata = GPS_METADATA | ({"gps_reported_at": "DATETIME NULL"} if table == "devices" else {})
                for column, definition in metadata.items():
                    if column not in fields:
                        cursor.execute(f"ALTER TABLE {table} ADD COLUMN {column} {definition}")
            cursor.execute("""INSERT IGNORE INTO devices (device_id, name, latitude, longitude, location_source, location_updated_at)
                SELECT s.device_id, s.device_id, s.latitude, s.longitude,
                       COALESCE(s.location_source, 'unknown'), s.location_updated_at FROM sensor_logs s
                INNER JOIN (SELECT device_id, MAX(id) id FROM sensor_logs GROUP BY device_id) latest ON s.id=latest.id""")
        connection.commit()
        _schema_ready = True

def get_db_connection():
    connection = pymysql.connect(**DB_CONFIG)
    try:
        ensure_schema(connection)
        return connection
    except Exception:
        connection.close()
        raise

@contextmanager
def database():
    connection = get_db_connection()
    try:
        yield connection
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()

def local_datetime(value):
    if value in (None, ""):
        return None
    try:
        stamp = value if isinstance(value, datetime) else datetime.fromisoformat(str(value).replace("Z", "+00:00"))
        return stamp.replace(tzinfo=LOCAL_TZ) if stamp.tzinfo is None else stamp.astimezone(LOCAL_TZ)
    except (ValueError, TypeError):
        return None

def iso_datetime(value):
    stamp = local_datetime(value)
    return stamp.isoformat(timespec="seconds") if stamp else None


def current_time():
    return datetime.now(LOCAL_TZ).replace(microsecond=0)


def location_source(value):
    return value if isinstance(value, str) and value in LOCATION_SOURCES else "unknown"


def location_json(values, now=None):
    """Expose only attributed fixes, never legacy default coordinates as a pin."""
    source = location_source(values.get("location_source"))
    stamp = local_datetime(values.get("location_updated_at"))
    position = coordinate_pair(values)
    now = now or current_time()
    age = (now-stamp).total_seconds() if stamp is not None else None
    if (source == "unknown" or position is None or
            stamp is None or age < -30):
        return {"latitude": None, "longitude": None, "location_source": source,
                "location_updated_at": None, "location_status": "unavailable"}
    if source == "manual":
        status = "manual"
    elif values.get("location_pending") or source == "gps" and values.get("gps_valid") in (0, False):
        status = "last_known"
    elif source == "lbs":
        status = "estimated" if age <= LOCATION_MAX_AGE_SECONDS else "last_known"
    else:
        status = "current" if age <= 120 else "last_known"
    return {"latitude": position[0], "longitude": position[1], "location_source": source,
            "location_updated_at": iso_datetime(stamp), "location_status": status}

def gps_json(values):
    valid = values.get("gps_valid")
    satellites = values.get("satellites")
    return {"gps_valid": bool(valid) if type(valid) in (bool, int) else None,
            "satellites": satellites if type(satellites) is int else None}

def warning_for(value):
    if value >= 38:
        return "danger", "CỰC KỲ NGUY HIỂM"
    if value >= 32:
        return "caution", "CẢNH BÁO NÓNG"
    return "normal", "AN TOÀN"

def reading_json(row):
    result = {key: float(value) if isinstance(value, Decimal) else value for key, value in row.items()}
    for key in ("temperature", "humidity", "heat_index"):
        result[key] = float(result[key]) if result.get(key) is not None else None
    if result["heat_index"] is None and result["temperature"] is not None and result["humidity"] is not None:
        result["heat_index"] = calculate_heat_index(result["temperature"], result["humidity"])
    result["created_at"] = iso_datetime(row.get("created_at"))
    result.update(location_json(row))
    result.update(gps_json(row))
    if result["heat_index"] is not None:
        result["warning_level"], result["warning_status"] = warning_for(result["heat_index"])
    else:
        result["warning_level"], result["warning_status"] = "unknown", "CHƯA CÓ DỮ LIỆU"
    return result

def valid_device_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9_.:-]{1,100}", value):
        raise ApiError("Mã thiết bị gồm 1–100 ký tự chữ, số hoặc _ . : -.")
    return value

def finite_number(value, name, minimum, maximum):
    try:
        if isinstance(value, bool):
            raise ValueError()
        result = float(value)
    except (ValueError, TypeError):
        raise ApiError(f"{name} phải là số.") from None
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise ApiError(f"{name} phải nằm trong khoảng {minimum} đến {maximum}.")
    return result

def request_limit(default=100):
    try:
        result = int(request.args.get("limit", default))
    except (ValueError, TypeError):
        raise ApiError("limit phải là số nguyên từ 1 đến 1000.") from None
    if not 1 <= result <= 1000:
        raise ApiError("limit phải là số nguyên từ 1 đến 1000.")
    return result

def filter_arguments():
    conditions, parameters, times = [], [], {}
    device_id = request.args.get("device_id")
    if device_id:
        conditions.append("device_id = %s")
        parameters.append(valid_device_id(device_id))
    for name, comparison in (("start", ">="), ("end", "<=")):
        value = request.args.get(name)
        if value:
            stamp = local_datetime(value)
            if stamp is None:
                raise ApiError(f"{name} phải là ngày giờ ISO 8601.")
            times[name] = stamp
            conditions.append(f"created_at {comparison} %s")
            parameters.append(stamp.replace(tzinfo=None))
    if "start" in times and "end" in times and times["start"] > times["end"]:
        raise ApiError("Thời gian bắt đầu phải trước thời gian kết thúc.")
    return (" WHERE " + " AND ".join(conditions) if conditions else ""), parameters

@app.get("/")
def website():
    return render_template("index.html", admin_view=False)

@app.get("/api/health")
def health():
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT 1")
    return jsonify(status="ok", server_time=datetime.now(LOCAL_TZ).isoformat(timespec="seconds"),
                   mqtt_connected=bool(mqtt_client and mqtt_client.is_connected()))

def load_devices():
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT * FROM devices ORDER BY enabled DESC, name, device_id")
        records = cursor.fetchall()
        cursor.execute("""SELECT s.* FROM sensor_logs s INNER JOIN
            (SELECT device_id, MAX(id) id FROM sensor_logs GROUP BY device_id) latest ON s.id=latest.id""")
        readings = {row["device_id"]: reading_json(row) for row in cursor.fetchall()}
    now, output = datetime.now(LOCAL_TZ), []
    for row in records:
        latest = readings.get(row["device_id"])
        seen = max(filter(None, (local_datetime(latest["created_at"]) if latest else None,
                                 local_datetime(row.get("gps_reported_at")))), default=None)
        output.append({"device_id": row["device_id"], "name": row["name"], "enabled": bool(row["enabled"]),
                       **location_json(row, now),
                       **gps_json(row),
                       "location_pending": bool(row.get("location_pending", False)),
                       "last_seen": iso_datetime(seen),
                       "is_online": bool(row["enabled"] and seen and 0 <= (now-seen).total_seconds() <= ONLINE_SECONDS),
                       "latest": latest})
    return output


@app.get("/api/devices")
def devices():
    return jsonify(load_devices())

def device_payload(body, existing=None):
    if not isinstance(body, dict):
        raise ApiError("Nội dung phải là JSON object.")
    data = dict(existing or {})
    data.update(body)
    device_id = valid_device_id(data.get("device_id"))
    name = data.get("name", device_id)
    if not isinstance(name, str) or not name.strip() or len(name.strip()) > 150:
        raise ApiError("Tên thiết bị phải có từ 1 đến 150 ký tự.")
    enabled = data.get("enabled", True)
    if not isinstance(enabled, bool):
        raise ApiError("enabled phải là true hoặc false.")
    coordinates_provided = "latitude" in body or "longitude" in body
    if existing is None or coordinates_provided:
        if "latitude" not in body or "longitude" not in body:
            raise ApiError("Cần cung cấp cùng lúc vĩ độ và kinh độ.")
        latitude = finite_number(body.get("latitude"), "Vĩ độ", -90, 90)
        longitude = finite_number(body.get("longitude"), "Kinh độ", -180, 180)
        if latitude == longitude == 0:
            raise ApiError("Tọa độ trạm (0, 0) không hợp lệ.")
        if (existing is not None and (latitude, longitude) == coordinate_pair(existing) and
                location_json(existing)["location_status"] != "unavailable"):
            # The admin form submits all fields even when only the name changed.
            source = location_source(existing.get("location_source"))
            updated_at = existing.get("location_updated_at")
        else:
            source, updated_at = "manual", current_time().replace(tzinfo=None)
    else:
        position = coordinate_pair(existing)
        latitude, longitude = position if position else (None, None)
        source = location_source(existing.get("location_source"))
        updated_at = existing.get("location_updated_at")
    return {"device_id": device_id, "name": name.strip(), "enabled": enabled,
            "latitude": latitude, "longitude": longitude,
            "location_source": source, "location_updated_at": updated_at}

@app.post("/api/devices")
@admin_required
def add_device():
    data = device_payload(request.get_json(silent=True))
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT device_id FROM devices WHERE device_id=%s", (data["device_id"],))
        if cursor.fetchone():
            raise ApiError("Mã thiết bị đã tồn tại.", 409, "device_exists")
        cursor.execute("INSERT INTO devices (device_id,name,latitude,longitude,enabled,location_source,location_updated_at) VALUES (%s,%s,%s,%s,%s,%s,%s)",
                       tuple(data[key] for key in ("device_id", "name", "latitude", "longitude", "enabled", "location_source", "location_updated_at")))
        connection.commit()
    data.update(location_json(data))
    return jsonify(data), 201

@app.put("/api/devices/<device_id>")
@admin_required
def update_device(device_id):
    valid_device_id(device_id)
    body = request.get_json(silent=True)
    if not isinstance(body, dict):
        raise ApiError("Nội dung phải là JSON object.")
    if body.get("device_id", device_id) != device_id:
        raise ApiError("Không thể thay đổi mã thiết bị.")
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT * FROM devices WHERE device_id=%s", (device_id,))
        existing = cursor.fetchone()
        if not existing:
            raise ApiError("Không tìm thấy thiết bị.", 404, "device_not_found")
        existing["enabled"] = bool(existing["enabled"])
        data = device_payload(body, existing)
        cursor.execute("UPDATE devices SET name=%s,latitude=%s,longitude=%s,enabled=%s,location_source=%s,location_updated_at=%s WHERE device_id=%s",
                       (data["name"], data["latitude"], data["longitude"], data["enabled"], data["location_source"], data["location_updated_at"], device_id))
        connection.commit()
    data.update(location_json(data))
    return jsonify(data)

@app.delete("/api/devices/<device_id>")
@admin_required
def archive_device(device_id):
    valid_device_id(device_id)
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT device_id FROM devices WHERE device_id=%s", (device_id,))
        if not cursor.fetchone():
            raise ApiError("Không tìm thấy thiết bị.", 404, "device_not_found")
        cursor.execute("UPDATE devices SET enabled=FALSE WHERE device_id=%s", (device_id,))
        connection.commit()
    return jsonify(device_id=device_id, enabled=False, message="Đã tạm ngưng thiết bị; lịch sử được giữ nguyên.")

@app.get("/api/sensor/latest")
def get_latest_data():
    where, parameters = filter_arguments()
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT * FROM sensor_logs"+where+" ORDER BY id DESC LIMIT 1", parameters)
        row = cursor.fetchone()
    if not row:
        raise ApiError("Chưa có dữ liệu đo cho điểm này.", 404, "no_data")
    return jsonify(reading_json(row))

@app.get("/api/sensor/history")
def get_history():
    where, parameters = filter_arguments()
    limit = request_limit()
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT * FROM sensor_logs"+where+" ORDER BY created_at DESC,id DESC LIMIT %s", parameters+[limit])
        rows = cursor.fetchall()
    return jsonify([reading_json(row) for row in reversed(rows)])

@app.get("/api/alerts")
def alerts():
    where, parameters = filter_arguments()
    where += (" AND " if where else " WHERE ")+"(heat_index >= 32 OR heat_index IS NULL)"
    limit = request_limit()
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("SELECT * FROM sensor_logs"+where+" ORDER BY created_at DESC,id DESC LIMIT %s", parameters+[limit])
        rows = cursor.fetchall()
    readings = [reading_json(row) for row in rows]
    return jsonify([row for row in readings if row["heat_index"] is not None and row["heat_index"] >= 32])


@app.get("/api/alerts/stream")
def alerts_stream():
    """Luồng Server-Sent Events (SSE) đẩy cảnh báo nóng bức theo thời gian thực."""
    device_id = request.args.get("device_id")
    if device_id:
        valid_device_id(device_id)
    subscriber = queue.Queue(maxsize=64)
    with _alert_lock:
        _alert_subscribers.add(subscriber)

    def generate():
        try:
            hello = json.dumps({"status": "live", "server_time": current_time().isoformat(timespec="seconds")}, ensure_ascii=False)
            yield f"event: connected\ndata: {hello}\n\n"
            while True:
                try:
                    payload = subscriber.get(timeout=20)
                except queue.Empty:
                    yield ": keepalive\n\n"
                    continue
                if device_id and payload.get("device_id") != device_id:
                    continue
                yield f"event: alert\ndata: {json.dumps(payload, ensure_ascii=False)}\n\n"
        finally:
            with _alert_lock:
                _alert_subscribers.discard(subscriber)

    headers = {
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",
        "Connection": "keep-alive",
    }
    return Response(stream_with_context(generate()), mimetype="text/event-stream", headers=headers)

@app.get("/api/model/metrics")
def model_metrics():
    metrics_file = Path(__file__).resolve().parent / "ml" / "evaluation_metrics.json"
    if not metrics_file.is_file():
        return jsonify(
            available=False,
            message="Chưa có báo cáo đánh giá. Chạy train_model.py để tạo chỉ số MAE, RMSE và R².",
        )
    try:
        report = json.loads(metrics_file.read_text(encoding="utf-8"))
        if not isinstance(report, dict) or "metrics" not in report:
            raise ValueError("Invalid metrics file")
        return jsonify(available=True, **report)
    except (OSError, ValueError):
        return jsonify(available=False, message="Không đọc được tệp evaluation_metrics.json.")


@app.get("/api/sensor/forecast")
def get_ai_forecast():
    device_id = request.args.get("device_id")
    if device_id:
        valid_device_id(device_id)
    with database() as connection, connection.cursor() as cursor:
        if not device_id:
            cursor.execute("SELECT device_id FROM sensor_logs ORDER BY id DESC LIMIT 1")
            latest = cursor.fetchone()
            if not latest:
                raise ApiError("Chưa có dữ liệu để dự báo.", 422, "insufficient_data")
            device_id = latest["device_id"]
        cursor.execute("""SELECT DATE_FORMAT(created_at, '%%Y-%%m-%%d %%H:00:00') AS hour,
            AVG(temperature) AS temperature, AVG(humidity) AS humidity,
            AVG(heat_index) AS heat_index FROM sensor_logs
            WHERE device_id=%s GROUP BY hour ORDER BY hour DESC LIMIT 12""", (device_id,))
        rows = cursor.fetchall()
        cursor.execute("SELECT * FROM sensor_logs WHERE device_id=%s ORDER BY id DESC LIMIT 1", (device_id,))
        latest = cursor.fetchone()
    hourly = forecast_hourly(rows, latest)
    predictions = [point["heat_index"] for point in hourly]
    level, warning = warning_for(max(predictions))
    return jsonify(device_id=device_id, current_heat_index=reading_json(latest)["heat_index"],
                   forecast_next_5_hours=predictions, hourly=hourly, warning_status=warning,
                   warning_level=level, generated_at=datetime.now(LOCAL_TZ).isoformat(timespec="seconds"),
                   model_status="experimental", model_note="Mô hình hiện tại được huấn luyện bằng dữ liệu mô phỏng; cần đánh giá bằng dữ liệu thực tế.")


def forecast_hourly(rows, latest):
    if len(rows) != 12 or not latest:
        raise ApiError("Cần đủ 12 giờ dữ liệu liên tiếp của điểm đo để dự báo 5 giờ tiếp theo.", 422, "insufficient_data")
    hours = [local_datetime(row["hour"]) for row in rows]
    if any(hour is None for hour in hours) or any(hours[index]-hours[index+1] != timedelta(hours=1) for index in range(11)):
        raise ApiError("Dữ liệu theo giờ bị thiếu. Cần 12 giờ liên tiếp để dự báo.", 422, "insufficient_data")
    seen = local_datetime(latest["created_at"])
    if not seen or datetime.now(LOCAL_TZ)-seen > timedelta(hours=2):
        raise ApiError("Dữ liệu gần nhất đã quá 2 giờ; chờ điểm đo cập nhật trước khi dự báo.", 422, "stale_data")
    try:
        predictions = run_lstm_forecast(rows)
    except ForecastUnavailable as error:
        raise ApiError(str(error), 503, "model_unavailable") from None
    return [{"time": iso_datetime(hours[0]+timedelta(hours=index+1)), "heat_index": value}
            for index, value in enumerate(predictions)]


def route_station_forecast(station):
    # Keep measurements from a previous site out of the forecast of a mobile station.
    lat, lon = station["latitude"], station["longitude"]
    with database() as connection, connection.cursor() as cursor:
        cursor.execute("""SELECT DATE_FORMAT(created_at, '%%Y-%%m-%%d %%H:00:00') AS hour,
            AVG(temperature) AS temperature, AVG(humidity) AS humidity,
            AVG(heat_index) AS heat_index FROM sensor_logs
            WHERE device_id=%s AND created_at >= %s AND created_at <= %s
            AND latitude BETWEEN %s AND %s AND longitude BETWEEN %s AND %s
            AND location_source IN ('gps','gnss') AND COALESCE(gps_valid, 1) = 1
            AND TIMESTAMPDIFF(SECOND, location_updated_at, created_at) BETWEEN 0 AND 120
            GROUP BY hour ORDER BY hour DESC LIMIT 12""",
            (station["device_id"], current_time().replace(tzinfo=None) - timedelta(hours=12),
             local_datetime(station["latest"]["created_at"]).replace(tzinfo=None),
             lat - .003, lat + .003, lon - .003, lon + .003))
        rows = cursor.fetchall()
    try:
        return forecast_hourly(rows, station["latest"])
    except ApiError:
        return []

def on_connect(client, userdata, flags, reason_code, properties=None):
    if reason_code == 0:
        client.subscribe(MQTT_TOPIC)
        app.logger.info("MQTT connected")

def coordinate_pair(values):
    """Chỉ nhận một cặp vị trí đầy đủ; không ghép hai nguồn tọa độ."""
    try:
        position = (finite_number(values.get("latitude"), "Vĩ độ", -90, 90),
                    finite_number(values.get("longitude"), "Kinh độ", -180, 180))
        return position if position != (0, 0) else None
    except ApiError:
        return None


def incoming_location(values, received_at, is_gps):
    """Position and the time of its fix, rather than the time of telemetry."""
    position = coordinate_pair(values)
    if position is None:
        return None
    source = values.get("location_source")
    source = source.strip().lower() if isinstance(source, str) else None
    if is_gps:
        if values.get("gps_valid") is not True or source not in (*GPS_SOURCES, "gnss", None):
            return None
        source = "gps"
    elif source not in ("lbs", "gnss"):
        return None
    try:
        max_age = 120 if source != "lbs" else LOCATION_MAX_AGE_SECONDS
        age = finite_number(values.get("location_age_s", 0), "Tuổi vị trí", 0, max_age)
    except ApiError:
        return None
    fixed_at = (received_at-timedelta(seconds=age)).replace(tzinfo=None)
    return (*position, source, fixed_at)


def saved_location(device):
    saved = location_json(device or {})
    if saved["location_status"] == "unavailable":
        return None, None, "unknown", None
    stamp = local_datetime(saved["location_updated_at"])
    return (saved["latitude"], saved["longitude"], saved["location_source"],
            stamp.replace(tzinfo=None))


def on_message(client, userdata, msg):
    try:
        data = json.loads(msg.payload.decode("utf-8"))
        device_id = valid_device_id(data.get("device_id"))
        has_reading = "temperature" in data or "humidity" in data
        if has_reading:
            temperature = finite_number(data.get("temperature"), "Nhiệt độ", -80, 100)
            humidity = finite_number(data.get("humidity"), "Độ ẩm", 0, 100)
        pending = data.get("location_pending", False)
        if not isinstance(pending, bool):
            raise ApiError("location_pending phải là true hoặc false.")
        raw_source = data.get("location_source")
        is_gps = ("gps_valid" in data or
                  isinstance(raw_source, str) and raw_source.strip().lower() in GPS_SOURCES)
        satellites = data.get("satellites")
        if type(satellites) is not int or not 0 <= satellites <= 99:
            satellites = None
        with database() as connection, connection.cursor() as cursor:
            cursor.execute("SELECT * FROM devices WHERE device_id=%s FOR UPDATE", (device_id,))
            device = cursor.fetchone()
            if device and not device["enabled"]:
                return
            received_at = current_time()
            incoming_position = incoming_location(data, received_at, is_gps)
            gps_valid = incoming_position is not None if is_gps else None
            previous = saved_location(device)
            coordinates_sent = any(key in data and (not is_gps or data[key] is not None)
                                   for key in ("latitude", "longitude"))
            if incoming_position is None and coordinates_sent:
                app.logger.warning("MQTT %s: vị trí/tuổi vị trí thiếu hoặc không hợp lệ; giữ vị trí đã lưu.", device_id)
            if incoming_position is not None and previous[3] is not None:
                lower_priority = (previous[2] == "gps" and incoming_position[2] != "gps" or
                                  previous[2] == "gnss" and incoming_position[2] == "lbs")
                older_same_source = incoming_position[2] == previous[2] and incoming_position[3] < previous[3]
                if lower_priority or older_same_source:
                    incoming_position = None
            pending = pending or incoming_position is None
            if not is_gps and previous[2] == "gps":
                pending = bool(device.get("location_pending", True))
            latitude, longitude, source, fixed_at = incoming_position or previous
            if not device:
                cursor.execute("INSERT INTO devices (device_id,name,latitude,longitude,location_source,location_updated_at) VALUES (%s,%s,%s,%s,%s,%s)",
                               (device_id, device_id, latitude, longitude, source, fixed_at))
            elif incoming_position is not None:
                cursor.execute("UPDATE devices SET latitude=%s,longitude=%s,location_source=%s,location_updated_at=%s WHERE device_id=%s",
                               (latitude, longitude, source, fixed_at, device_id))
            # Remember an unsuccessful/new positioning attempt independently of
            # sensor timestamps. Keep the last trusted pair and its original age.
            if not device or bool(device.get("location_pending", True)) != pending:
                cursor.execute("UPDATE devices SET location_pending=%s WHERE device_id=%s", (pending, device_id))
            received_at_db = received_at.replace(tzinfo=None)
            if is_gps:
                cursor.execute("UPDATE devices SET gps_valid=%s,satellites=%s,gps_reported_at=%s WHERE device_id=%s",
                               (gps_valid, satellites, received_at_db, device_id))
            alert_event = None
            if has_reading:
                hi = calculate_heat_index(temperature, humidity)
                cursor.execute("""INSERT INTO sensor_logs
                (device_id,temperature,humidity,heat_index,latitude,longitude,created_at,location_source,location_updated_at,gps_valid,satellites)
                VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
                               (device_id, temperature, humidity, hi, latitude, longitude,
                                received_at_db, source, fixed_at, gps_valid, satellites if is_gps else None))
                if hi >= 32:
                    alert_event = reading_json({
                        "id": cursor.lastrowid,
                        "device_id": device_id,
                        "device_name": (device.get("name") if device else None) or device_id,
                        "temperature": temperature,
                        "humidity": humidity,
                        "heat_index": hi,
                        "latitude": latitude,
                        "longitude": longitude,
                        "location_source": source,
                        "location_updated_at": fixed_at,
                        "gps_valid": gps_valid,
                        "satellites": satellites if is_gps else None,
                        "created_at": received_at_db,
                    })
            connection.commit()
            if alert_event is not None:
                publish_realtime_alert(alert_event)
            app.logger.info("MQTT saved device=%s location=%s pending=%s received_at=%s",
                            device_id, source, pending, received_at.isoformat())
    except (ValueError, TypeError, AttributeError, ApiError, pymysql.MySQLError):
        app.logger.exception("Không thể nhận bản tin MQTT")

def start_mqtt():
    """Chỉ kết nối khi khởi chạy máy chủ, không có tác dụng phụ lúc import/test."""
    global mqtt_client
    if os.getenv("MQTT_ENABLED", "1").lower() in ("0", "false", "no"):
        return
    try:
        import paho.mqtt.client as mqtt
        mqtt_client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)
        mqtt_client.on_connect = on_connect
        mqtt_client.on_message = on_message
        mqtt_client.connect_async(MQTT_BROKER, MQTT_PORT, 60)
        mqtt_client.loop_start()
    except (ImportError, OSError):
        app.logger.exception("MQTT chưa sẵn sàng; REST API vẫn hoạt động")

init_rain_routes(app, load_devices, route_station_forecast)


if __name__ == "__main__":
    start_mqtt()
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "5000")), debug=os.getenv("FLASK_DEBUG", "0")=="1", use_reloader=False, threaded=True)
