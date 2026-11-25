"""Heat evidence for individual timed road segments."""
from bisect import bisect_left
from datetime import datetime
import math

try:
    from .ml.ml_service import calculate_heat_index
except ImportError:
    from ml.ml_service import calculate_heat_index

STATION_RADIUS_KM = 2
FRESH_SECONDS = 120
MEASUREMENT_WINDOW_SECONDS = 15 * 60


def timestamp(value):
    try:
        stamp = datetime.fromisoformat(value)
        return stamp.timestamp() if stamp.tzinfo is not None else None
    except (TypeError, ValueError, OSError, OverflowError):
        return None


def age_within(now, stamp, seconds):
    value = timestamp(stamp)
    return value is not None and 0 <= now - value <= seconds


def station_candidates(stations, now, distance):
    for station in stations:
        if (not station["enabled"] or not station["is_online"]
                or station["location_status"] != "current"
                or station["location_source"] not in ("gps", "gnss")
                or station["gps_valid"] is False
                or not age_within(now, station["location_updated_at"], FRESH_SECONDS)):
            continue
        reading = station["latest"]
        if not reading or not age_within(now, reading["created_at"], FRESH_SECONDS):
            continue
        if not all(isinstance(reading.get(k), (int, float)) and math.isfinite(reading[k])
                   for k in ("temperature", "humidity", "heat_index")):
            continue
        if not 0 <= reading["humidity"] <= 100:
            continue
        point = (station["latitude"], station["longitude"])
        measurement_point = (reading.get("latitude"), reading.get("longitude"))
        if (None in measurement_point or reading.get("location_source") not in ("gps", "gnss")
                or reading.get("gps_valid") is False
                or not age_within(timestamp(reading["created_at"]), reading.get("location_updated_at"), FRESH_SECONDS)
                or distance(point, measurement_point) > .5):
            continue
        yield station, point, measurement_point


def interpolate_hour(times, values, arrival):
    """Match an exact timestamp or interpolate between two consecutive hours."""
    if not isinstance(values, list):
        return None
    index = bisect_left(times, arrival)
    if index >= len(times):
        return None
    if index >= len(values):
        return None
    right = values[index]
    if not isinstance(right, (int, float)) or isinstance(right, bool) or not math.isfinite(right):
        return None
    if times[index] == arrival:
        return right
    if index == 0 or times[index] - times[index - 1] != 3600:
        return None
    left = values[index - 1]
    if not isinstance(left, (int, float)) or isinstance(left, bool) or not math.isfinite(left):
        return None
    return left + (right - left) * (arrival - times[index - 1]) / 3600


def observed_heat(segment, geometry, candidates, forecast, distance):
    arrival = timestamp(segment["passed_at"])
    # Radius is checked on the entire sampled geometry. The GPS fix associated
    # with this reading must also cover the segment if we use the reading.
    points = geometry[segment["start_index"]:segment["end_index"] + 1]
    matches = []
    for station, point, measurement_point in candidates:
        proximity = distance(segment["point"], point)
        if proximity <= STATION_RADIUS_KM and all(distance(vertex, point) <= STATION_RADIUS_KM for vertex in points):
            matches.append((proximity, station, measurement_point))
    matches.sort(key=lambda entry: (entry[0], entry[1]["device_id"]))
    for proximity, station, measurement_point in matches:
        reading = station["latest"]
        if (age_within(arrival, reading["created_at"], MEASUREMENT_WINDOW_SECONDS)
                and all(distance(vertex, measurement_point) <= STATION_RADIUS_KM for vertex in points)):
            return {"heat_index": reading["heat_index"], "temperature": reading["temperature"],
                    "humidity": reading["humidity"], "heat_source": "esp32",
                    "station_id": station["device_id"], "station_name": station["name"],
                    "station_distance_km": round(distance(segment["point"], measurement_point), 2),
                    "measured_at": reading["created_at"]}
    for proximity, station, _ in matches:
        anchor = int(timestamp(station["latest"]["created_at"]) // 3600) * 3600
        if not anchor + 3600 <= arrival <= anchor + 5 * 3600:
            continue
        hours = forecast(station)
        index = interpolate_hour([timestamp(hour["time"]) for hour in hours],
                                 [hour["heat_index"] for hour in hours], arrival)
        if index is not None:
            return {"heat_index": index, "heat_source": "lstm", "station_id": station["device_id"],
                    "station_name": station["name"], "station_distance_km": round(proximity, 2)}
    return None


def modeled_heat(hourly, times, arrival):
    temperature = interpolate_hour(times, hourly.get("temperature_2m") or [], arrival)
    humidity = interpolate_hour(times, hourly.get("relative_humidity_2m") or [], arrival)
    if temperature is None or humidity is None or not -80 <= temperature <= 65 or not 0 <= humidity <= 100:
        return None
    return {"heat_index": calculate_heat_index(temperature, humidity), "temperature": temperature,
            "humidity": humidity, "heat_source": "open_meteo"}


def heat_risk(value):
    if value is None:
        return "unknown"
    return "high" if value >= 38 else "moderate" if value >= 32 else "low"


def heat_exposure(value):
    if value < 32:
        return 0
    return min(1, .35 + .65 * (value - 32) / 6)
