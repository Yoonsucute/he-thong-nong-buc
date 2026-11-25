"""Current model conditions and hourly forecasts for a HeatWatch location."""
from datetime import datetime, timedelta, timezone

from flask import Blueprint, current_app, jsonify, request

try:
    from .rain_routes import RouteError, coordinate, http_json, number, route_error
except ImportError:
    from rain_routes import RouteError, coordinate, http_json, number, route_error

weather_api = Blueprint("weather", __name__)
weather_api.register_error_handler(RouteError, route_error)
FIELDS = "temperature_2m,relative_humidity_2m,weather_code,is_day"
CONDITIONS = {
    0: ("clear", "Trời quang"), 1: ("partly-cloudy", "Ít mây"),
    2: ("partly-cloudy", "Mây rải rác"), 3: ("cloudy", "Nhiều mây"),
    45: ("fog", "Sương mù"), 48: ("fog", "Sương mù đóng băng"),
    51: ("rain", "Mưa phùn nhẹ"), 53: ("rain", "Mưa phùn"),
    55: ("rain", "Mưa phùn dày"), 56: ("rain", "Mưa phùn đóng băng"),
    57: ("rain", "Mưa phùn đóng băng nặng"), 61: ("rain", "Mưa nhẹ"),
    63: ("rain", "Có mưa"), 65: ("rain", "Mưa lớn"),
    66: ("rain", "Mưa đóng băng nhẹ"), 67: ("rain", "Mưa đóng băng nặng"),
    71: ("snow", "Tuyết nhẹ"), 73: ("snow", "Có tuyết"),
    75: ("snow", "Tuyết dày"), 77: ("snow", "Hạt tuyết"),
    80: ("rain", "Mưa rào nhẹ"), 81: ("rain", "Mưa rào"),
    82: ("rain", "Mưa rào mạnh"), 85: ("snow", "Mưa tuyết nhẹ"),
    86: ("snow", "Mưa tuyết mạnh"), 95: ("storm", "Dông"),
    96: ("storm", "Dông kèm mưa đá nhẹ"), 97: ("storm", "Dông mạnh"),
    99: ("storm", "Dông kèm mưa đá lớn"),
}


def optional_number(value, minimum, maximum):
    try:
        return number(value, minimum, maximum)
    except (ValueError, TypeError, OverflowError):
        return None


def weather_row(time, fields, zone):
    icon, description = CONDITIONS.get(
        optional_number(fields.get("weather_code"), 0, 99),
        ("unknown", "Chưa rõ trạng thái trời"),
    )
    if optional_number(fields.get("is_day"), 0, 1) == 0:
        icon = {"clear": "night", "partly-cloudy": "partly-cloudy-night"}.get(icon, icon)
    return {
        "time": datetime.fromtimestamp(time, zone).isoformat(timespec="minutes"),
        "temperature": optional_number(fields.get("temperature_2m"), -100, 80),
        "humidity": optional_number(fields.get("relative_humidity_2m"), 0, 100),
        "rain_probability": optional_number(fields.get("precipitation_probability"), 0, 100),
        "icon": icon,
        "description": description,
    }


def normalize_weather(data):
    current, hours = data["current"], data["hourly"]
    if not isinstance(hours["time"], list):
        raise ValueError("hourly timestamps must be an array")
    zone = timezone(timedelta(seconds=number(data["utc_offset_seconds"], -14 * 3600, 14 * 3600)))
    now = number(current["time"], 0, 4_102_444_800)
    rows = []
    for index, stamp in enumerate(hours["time"]):
        time = optional_number(stamp, 0, 4_102_444_800)
        if time is None or not now < time <= now + 12 * 3600:
            continue
        fields = {
            field: values[index] for field, values in hours.items()
            if field != "time" and isinstance(values, list) and index < len(values)
        }
        rows.append((time, weather_row(time, fields, zone)))
    rows.sort(key=lambda item: item[0])
    conditions = weather_row(now, current, zone)
    # Open-Meteo hourly probability is for the hour ending at its timestamp.
    if rows and rows[0][0] <= now + 3600:
        conditions["rain_probability"] = rows[0][1]["rain_probability"]
        conditions["rain_until"] = rows[0][1]["time"]
    return {"source": "Open-Meteo", "current": conditions, "hourly": [row for _, row in rows]}


@weather_api.get("/api/weather")
def weather():
    latitude, longitude = coordinate(request.args.get("point", ""))
    current_only = request.args.get("current_only") == "1"
    try:
        data = http_json(current_app.config["OPEN_METEO_URL"], params={
            "latitude": f"{latitude:.2f}", "longitude": f"{longitude:.2f}",
            "current": FIELDS,
            "hourly": "precipitation_probability" if current_only else f"{FIELDS},precipitation_probability",
            "timeformat": "unixtime", "timezone": "auto", "forecast_hours": 2 if current_only else 13,
        }, provider="conditions", ttl=600)
        result = normalize_weather(data)
        if current_only:
            del result["hourly"]
        return jsonify(result)
    except RouteError:
        raise RouteError("Open-Meteo tạm thời không phản hồi. Vui lòng thử lại.", 503, "weather_unavailable") from None
    except (AttributeError, KeyError, TypeError, ValueError, OSError, OverflowError):
        raise RouteError("Open-Meteo trả về dữ liệu thời tiết không hợp lệ.", 502, "weather_invalid") from None
