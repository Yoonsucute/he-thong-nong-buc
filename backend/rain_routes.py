"""Public, read-only route planning with Valhalla and hourly Open-Meteo rain.

Weather is sampled along timed geometry, never inferred from HeatWatch sensors
or the heat-index LSTM. Missing forecasts remain unknown, not dry.
"""
from bisect import bisect_left, bisect_right
from collections import OrderedDict
from datetime import datetime, timedelta, timezone
import copy
import json
import math
import os
import socket
import threading
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from flask import Blueprint, current_app, jsonify, request
from pymysql import MySQLError

try:
    from .route_heat import heat_exposure, heat_risk, modeled_heat, observed_heat, station_candidates
except ImportError:
    from route_heat import heat_exposure, heat_risk, modeled_heat, observed_heat, station_candidates

bp = Blueprint("rain_routes", __name__)
VIETNAM_TZ = timezone(timedelta(hours=7))
_cache = OrderedDict()
_cache_lock = threading.Lock()
_provider_locks = {name: threading.Lock() for name in ("valhalla", "geocoder", "weather", "conditions")}
_last_request = {}
_capacity = threading.BoundedSemaphore(2)


class RouteError(Exception):
    def __init__(self, message, status=400, code="invalid_route_request"):
        self.message, self.status, self.code = message, status, code


@bp.errorhandler(RouteError)
def route_error(error):
    return jsonify(error=error.message, code=error.code), error.status


def utc_now():
    return datetime.now(timezone.utc)


def number(value, minimum, maximum):
    if isinstance(value, bool) or value is None:
        raise ValueError("invalid number")
    result = float(value)
    if not math.isfinite(result) or not minimum <= result <= maximum:
        raise ValueError("number outside bounds")
    return result


def coordinate(value):
    try:
        parts = value.split(",") if isinstance(value, str) else value
        if len(parts) != 2:
            raise ValueError("coordinate pair required")
        return [number(parts[0], -90, 90), number(parts[1], -180, 180)]
    except (ValueError, TypeError, OverflowError):
        raise RouteError("Tọa độ cần có dạng vĩ độ, kinh độ và nằm trong phạm vi hợp lệ.") from None


def departure_time(value, now=None):
    now = now or utc_now()
    if value in (None, "", "now"):
        return now.replace(microsecond=0)
    try:
        result = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if result.tzinfo is None:
            result = result.replace(tzinfo=VIETNAM_TZ)
        result = result.astimezone(timezone.utc)
    except (ValueError, TypeError, AttributeError, OverflowError):
        raise RouteError("Giờ khởi hành không hợp lệ.") from None
    if result < now - timedelta(minutes=1) or result > now + timedelta(days=6):
        raise RouteError("Chọn giờ khởi hành từ hiện tại đến tối đa 6 ngày tới.")
    return result


def distance(a, b):
    lat1, lat2 = math.radians(a[0]), math.radians(b[0])
    dlat, dlon = lat2 - lat1, math.radians(b[1] - a[1])
    value = math.sin(dlat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(dlon / 2) ** 2
    return 6371.0088 * 2 * math.asin(min(1, math.sqrt(value)))


def http_json(url, *, params=None, payload=None, provider, ttl=300):
    """Bounded cache and per-provider pacing, including concurrent requests."""
    if params:
        url += "?" + urlencode(params)
    body = json.dumps(payload, sort_keys=True).encode() if payload is not None else None
    key = (url, body)
    with _provider_locks[provider]:
        now = time.monotonic()
        with _cache_lock:
            cached = _cache.get(key)
            if cached and now - cached[0] < ttl:
                _cache.move_to_end(key)
                return copy.deepcopy(cached[1])
        if provider in ("geocoder", "valhalla"):
            time.sleep(max(0, 1.05 - (now - _last_request.get(provider, -100))))
        headers = {"User-Agent": current_app.config["ROUTING_USER_AGENT"], "Accept": "application/json"}
        if body is not None:
            headers["Content-Type"] = "application/json"
        try:
            _last_request[provider] = time.monotonic()
            with urlopen(Request(url, data=body, headers=headers), timeout=12) as response:
                raw = response.read(8_000_001)
            if len(raw) > 8_000_000:
                raise ValueError("upstream response too large")
            data = json.loads(raw)
        except HTTPError as error:
            if provider == "valhalla" and error.code in (400, 404):
                raise RouteError("Không tìm được tuyến phù hợp với phương tiện và hai điểm đã chọn.", 422, "route_not_found") from None
            raise RouteError("Dịch vụ tìm đường hoặc thời tiết tạm thời không phản hồi. Vui lòng thử lại.", 503, f"{provider}_unavailable") from None
        except (URLError, OSError, socket.timeout, ValueError):
            raise RouteError("Không kết nối được dịch vụ tìm đường hoặc thời tiết. Vui lòng thử lại.", 503, f"{provider}_unavailable") from None
        with _cache_lock:
            _cache[key] = (time.monotonic(), data)
            _cache.move_to_end(key)
            while len(_cache) > 128:
                _cache.popitem(last=False)
        return copy.deepcopy(data)


def decode_shape(encoded):
    """Valhalla native shape is a polyline with six decimal places."""
    if not isinstance(encoded, str) or len(encoded) > 1_000_000:
        raise ValueError("invalid shape")
    result, offset, lat, lon = [], 0, 0, 0
    while offset < len(encoded):
        values = []
        for _ in range(2):
            value, shift = 0, 0
            while True:
                if offset >= len(encoded) or shift > 30:
                    raise ValueError("truncated shape")
                byte = ord(encoded[offset]) - 63
                offset += 1
                if not 0 <= byte <= 63:
                    raise ValueError("invalid shape byte")
                value |= (byte & 31) << shift
                shift += 5
                if byte < 32:
                    break
            values.append(~(value >> 1) if value & 1 else value >> 1)
        lat, lon = lat + values[0], lon + values[1]
        result.append(coordinate([lat / 1e6, lon / 1e6]))
        if len(result) > 50_000:
            raise ValueError("shape too long")
    if len(result) < 2:
        raise ValueError("shape too short")
    return result


def unpack_trip(trip):
    # A two-point request should have one leg. Keep this invariant explicit.
    leg, = trip["legs"]
    shape = decode_shape(leg["shape"])
    length = number(trip["summary"]["length"], 0.001, 1000)
    duration = number(trip["summary"]["time"], 1, 18 * 3600)
    cumulative = [0.0]
    for left, right in zip(shape, shape[1:]):
        cumulative.append(cumulative[-1] + distance(left, right))
    if cumulative[-1] <= 0:
        raise ValueError("empty route")
    # Allocate each maneuver's duration by distance inside that maneuver. This
    # preserves differing road speeds and intersection delays across the route.
    edge_times = [None] * (len(shape) - 1)
    for maneuver in leg.get("maneuvers", []):
        begin, end = int(maneuver["begin_shape_index"]), int(maneuver["end_shape_index"])
        seconds = number(maneuver.get("time", 0), 0, duration + 1)
        if not 0 <= begin <= end < len(shape):
            raise ValueError("invalid maneuver indices")
        span = cumulative[end] - cumulative[begin]
        if end > begin:
            for index in range(begin, end):
                weight = (cumulative[index + 1] - cumulative[index]) / span if span else 1 / (end - begin)
                if edge_times[index] is None:
                    edge_times[index] = 0
                edge_times[index] += seconds * weight
    for index, seconds in enumerate(edge_times):
        if seconds is None:
            edge_times[index] = duration * (cumulative[index + 1] - cumulative[index]) / cumulative[-1]
    total = sum(edge_times)
    if total <= 0:
        raise ValueError("invalid route duration")
    elapsed = [0.0]
    for seconds in edge_times:
        elapsed.append(elapsed[-1] + seconds * duration / total)
    return {"distance_km": length, "duration_seconds": duration, "geometry": shape,
            "elapsed": elapsed, "has_time_restrictions": bool(trip["summary"].get("has_time_restrictions"))}


def samples_for_route(route, departure):
    shape, elapsed = route["geometry"], route["elapsed"]
    # Aim for <=2km / <=5min, capped to bound external API use on long routes.
    count = min(24, max(1, math.ceil(route["distance_km"] / 2), math.ceil(route["duration_seconds"] / 300)))
    times = [route["duration_seconds"] * i / count for i in range(count + 1)]

    def point_at(offset):
        right = min(len(shape) - 1, bisect_right(elapsed, offset))
        left = right - 1
        lat1, lon1 = shape[left]
        lat2, lon2 = shape[right]
        fraction = (offset - elapsed[left]) / (elapsed[right] - elapsed[left]) if elapsed[right] > elapsed[left] else 0
        longitude = (lon1 + ((lon2 - lon1 + 180) % 360 - 180) * fraction + 180) % 360 - 180
        return [lat1 + (lat2 - lat1) * fraction, longitude]

    # Insert exact cut points even where Valhalla returned a single long edge.
    geometry, cuts, cursor = [shape[0]], [0], 1
    for offset in times[1:-1]:
        while cursor < len(shape) and elapsed[cursor] <= offset:
            geometry.append(shape[cursor])
            cursor += 1
        if elapsed[cursor - 1] != offset:
            geometry.append(point_at(offset))
        cuts.append(len(geometry) - 1)
    geometry.extend(shape[cursor:])
    cuts.append(len(geometry) - 1)
    route["geometry"] = geometry
    samples = []
    for index, (begin, end) in enumerate(zip(cuts, cuts[1:])):
        seconds = times[index + 1] - times[index]
        midpoint = times[index] + seconds / 2
        passed_at = departure + timedelta(seconds=midpoint)
        samples.append({"start_index": begin, "end_index": end, "point": point_at(midpoint),
                        "passed_at": passed_at.isoformat(), "duration_seconds": seconds})
    return samples


def weather_times(hourly):
    times = hourly.get("time", [])
    if (not isinstance(times, list) or not times
            or any(isinstance(t, bool) or not isinstance(t, (int, float)) or not math.isfinite(t) for t in times)
            or any(a >= b for a, b in zip(times, times[1:]))):
        return []
    return times


def weather_at(hourly, passed_at, times=None):
    """Hourly rain describes the preceding hour: use the END of that interval."""
    times = weather_times(hourly) if times is None else times
    if not times:
        return None
    arrival = datetime.fromisoformat(passed_at).timestamp()
    index = bisect_left(times, arrival)
    if arrival < times[0] - 3600 or index >= len(times):
        return None
    try:
        probability = number(hourly["precipitation_probability"][index], 0, 100)
        precipitation = number(hourly["precipitation"][index], 0, 1000)
        if times[index] - arrival >= 3600:
            return None
    except (KeyError, IndexError, ValueError, TypeError):
        return None
    risk = "high" if probability >= 60 or precipitation >= 2 else "moderate" if probability >= 30 or precipitation >= .2 else "low"
    return {"probability_percent": probability, "precipitation_mm": precipitation,
            "forecast_hour": datetime.fromtimestamp(times[index], timezone.utc).isoformat(), "risk": risk}


def assess_routes(routes, departure):
    for route in routes:
        route["segments"] = samples_for_route(route, departure)
    points = list(dict.fromkeys(tuple(segment["point"]) for route in routes for segment in route["segments"]))
    start = departure.astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)
    end = (departure + timedelta(seconds=max(r["duration_seconds"] for r in routes), hours=1)).astimezone(timezone.utc).replace(minute=0, second=0, microsecond=0)
    warnings = []
    try:
        data = http_json(current_app.config["OPEN_METEO_URL"], params={
            "latitude": ",".join(str(p[0]) for p in points), "longitude": ",".join(str(p[1]) for p in points),
            "hourly": "precipitation_probability,precipitation,temperature_2m,relative_humidity_2m",
            "timezone": "GMT", "timeformat": "unixtime",
            "start_hour": start.strftime("%Y-%m-%dT%H:%M"), "end_hour": end.strftime("%Y-%m-%dT%H:%M"),
        }, provider="weather", ttl=600)
        records = data if isinstance(data, list) else [data]
        if len(records) != len(points) or any(not isinstance(row, dict) for row in records):
            raise ValueError("unexpected weather locations")
        forecasts = dict(zip(points, records))
    except (RouteError, ValueError, TypeError):
        forecasts = {}
        warnings.append("Không tải được dự báo từ Open-Meteo.")
    load_stations, load_forecast = current_app.extensions["route_heat"]
    station_forecasts = {}
    now = utc_now().timestamp()
    try:
        stations = list(station_candidates(load_stations(), now, distance))
    except MySQLError:
        stations = []
        warnings.append("Chưa truy cập được số đo ESP32.")

    def forecast(station):
        key = station["device_id"]
        if key not in station_forecasts:
            try:
                station_forecasts[key] = load_forecast(station)
            except MySQLError:
                station_forecasts[key] = []
        return station_forecasts[key]

    risk_order = {"low": 0, "moderate": 1, "high": 2}
    for route in routes:
        rain_score = expected = rain_seconds = risk_time = heat_score = 0
        sources = dict.fromkeys(("esp32", "lstm", "open_meteo", "unknown"), 0.0)
        nearby = {}
        peaks, probabilities = [], []
        for segment in route["segments"]:
            hourly = forecasts.get(tuple(segment["point"]), {}).get("hourly", {})
            hourly = hourly if isinstance(hourly, dict) else {}
            times = weather_times(hourly)
            weather = weather_at(hourly, segment["passed_at"], times)
            arrival = datetime.fromisoformat(segment["passed_at"]).timestamp()
            heat = observed_heat(segment, route["geometry"], stations, forecast, distance)
            heat = heat or modeled_heat(hourly, times, arrival)
            seconds = segment["duration_seconds"]
            minutes = seconds / 60
            segment.update(probability_percent=None, precipitation_mm=None, forecast_hour=None)
            if weather:
                segment.update(weather)
            rain_risk = weather["risk"] if weather else "unknown"
            segment.update(heat_index=None, temperature=None, humidity=None, heat_source="unknown")
            if heat:
                segment.update(heat)
                segment["heat_index"] = round(heat["heat_index"], 1)
                peaks.append(segment["heat_index"])
                heat_score += heat_exposure(segment["heat_index"]) * minutes
                if heat.get("station_id"):
                    nearby[heat["station_id"]] = heat["station_name"]
            sources[segment["heat_source"]] += seconds
            heat_level = heat_risk(segment["heat_index"])
            segment.update(heat_risk=heat_level, rain_risk=rain_risk,
                           risk=max((rain_risk, heat_level), key=risk_order.get) if heat and weather else "unknown")
            if weather:
                rain_seconds += seconds
                probabilities.append(weather["probability_percent"])
                expected += weather["probability_percent"] / 100 * minutes
                rain_score += min(1, weather["probability_percent"] / 100 + .35 * min(weather["precipitation_mm"] / 5, 1)) * minutes
                if rain_risk in ("moderate", "high"):
                    risk_time += minutes
        rain_complete = all(s["rain_risk"] != "unknown" for s in route["segments"])
        heat_complete = sources["unknown"] == 0
        total = route["duration_seconds"]
        peak = round(max(peaks), 1) if peaks else None
        route.update(weather_complete=rain_complete, heat_complete=heat_complete,
                     weather_coverage_percent=round(100 * rain_seconds / total, 1),
                     heat_coverage_percent=round(100 * (1 - sources["unknown"] / total), 1),
                     heat_source_percent={key: round(100 * seconds / total, 1) for key, seconds in sources.items()},
                     nearby_stations=[{"id": key, "name": name} for key, name in nearby.items()],
                     max_heat_index=peak, heat_risk=heat_risk(peak),
                     max_rain_probability=max(probabilities, default=None),
                     rain_score=round(rain_score, 4) if rain_complete else None,
                     combined_exposure_minutes=round(.6 * heat_score + .4 * rain_score, 4) if heat_complete and rain_complete else None,
                     expected_rain_minutes=round(expected, 1) if rain_complete else None,
                     risky_minutes=round(risk_time, 1) if rain_complete else None,
                     arrival_at=(departure + timedelta(seconds=route["duration_seconds"])).isoformat())
        del route["elapsed"]
    if any(r["combined_exposure_minutes"] is None for r in routes):
        warnings.append("Chưa đủ dữ liệu nóng bức và mưa trên tất cả các tuyến để xếp hạng rủi ro.")
    if any(not hours for hours in station_forecasts.values()):
        warnings.append("Một số trạm gần tuyến chưa có dự báo LSTM phù hợp tại vị trí đo.")
    return " ".join(warnings)


def rank_routes(routes):
    shortest = min(routes, key=lambda r: (r["distance_km"], r["duration_seconds"]))
    if any(route.get("combined_exposure_minutes") is None for route in routes):
        return None, shortest, None
    lowest_risk = min(routes, key=lambda r: (r["combined_exposure_minutes"], r["duration_seconds"], r["distance_km"]))
    metrics = {"combined_exposure_minutes": .60, "duration_seconds": .25, "distance_km": .15}
    maxima = {key: max(route[key] for route in routes) or 1 for key in metrics}
    for route in routes:
        route["comparison_score"] = sum(weight * route[key] / maxima[key] for key, weight in metrics.items())
    recommended = min(routes, key=lambda r: (r["comparison_score"], r["combined_exposure_minutes"], r["duration_seconds"]))
    return recommended, shortest, lowest_risk


def find_routes(start, end, vehicle, departure):
    # Resolve the ORIGIN timezone, not the browser/server timezone. This also
    # correctly handles trips outside Vietnam and departure-date DST changes.
    warnings = []
    try:
        metadata = http_json(current_app.config["OPEN_METEO_URL"], params={
            "latitude": start[0], "longitude": start[1], "timezone": "auto", "forecast_days": 1,
        }, provider="weather", ttl=3600)
        origin_zone = ZoneInfo(metadata["timezone"])
    except (RouteError, KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
        origin_zone = None
        warnings.append("Chưa xác định được múi giờ điểm đi. Valhalla ước tính hành trình bằng cấu hình mặc định.")
    costing = "motor_scooter" if vehicle == "motorcycle" else "auto"
    base_options = {"top_speed": 60, "use_highways": 0} if vehicle == "motorcycle" else {}
    profiles = [{}, {"shortest": True}, {"use_highways": 0, "use_tolls": 0, "use_ferry": 0}]
    routes, seen = [], set()
    for profile in profiles:
        payload = {"locations": [{"lat": start[0], "lon": start[1]}, {"lat": end[0], "lon": end[1]}],
                   "costing": costing, "costing_options": {costing: base_options | profile},
                   "units": "kilometers", "directions_type": "maneuvers"}
        if origin_zone is not None:
            payload["date_time"] = {"type": 1, "value": departure.astimezone(origin_zone).strftime("%Y-%m-%dT%H:%M")}
        try:
            data = http_json(current_app.config["VALHALLA_URL"].rstrip("/") + "/route", payload=payload, provider="valhalla")
            if not isinstance(data, dict) or data.get("trip", {}).get("status", 0) != 0:
                raise ValueError("invalid trip status")
            route = unpack_trip(data["trip"])
            signature = tuple(tuple(p) for p in route["geometry"])
            if signature not in seen:
                seen.add(signature)
                route["id"] = f"route-{len(routes) + 1}"
                routes.append(route)
        except (RouteError, KeyError, ValueError, TypeError, OverflowError):
            warnings.append("Một tùy chọn tìm đường không trả được tuyến phù hợp.")
    if not routes:
        raise RouteError("Không tìm được tuyến phù hợp hoặc Valhalla đang không phản hồi. Thử điểm gần đường hơn.", 503 if warnings else 422, "routing_unavailable")
    warning = assess_routes(routes, departure)
    if warning:
        warnings.append(warning)
    recommended, shortest, lowest_risk = rank_routes(routes)
    return {"routes": routes, "recommended_route_id": recommended["id"] if recommended else None,
            "shortest_route_id": shortest["id"], "lowest_risk_route_id": lowest_risk["id"] if lowest_risk else None,
            "reasons": {"recommended": "Cân bằng điểm rủi ro (60%), thời gian (25%) và quãng đường (15%).",
                        "shortest": "Quãng đường ngắn nhất trong các tuyến Valhalla tìm được.",
                        "lowest_risk": "Mức phơi nhiễm thấp nhất theo thời gian đi qua từng đoạn, ưu tiên giảm nóng bức (60%) và mưa (40%)."},
            "departure_at": departure.isoformat(), "origin_timezone": str(origin_zone) if origin_zone else None,
            "vehicle": vehicle, "start": start, "end": end,
            "generated_at": utc_now().isoformat(), "warnings": list(dict.fromkeys(warnings)),
            "method": "time_weighted_heat_rain_and_travel", "sample_limit_per_route": 24,
            "attribution": {"routing": "Valhalla / OpenStreetMap", "weather": "Open-Meteo"}}


@bp.get("/api/rain-route/geocode")
def geocode():
    query = request.args.get("q", "").strip()
    if not 3 <= len(query) <= 200:
        raise RouteError("Nhập địa chỉ từ 3 đến 200 ký tự rồi bấm tìm.")
    try:
        point = coordinate(query)
        return jsonify(results=[{"label": f"{point[0]:.6f}, {point[1]:.6f}", "point": point}])
    except RouteError:
        pass
    data = http_json(current_app.config["GEOCODER_URL"], params={"q": query, "format": "jsonv2", "limit": 5, "accept-language": "vi"}, provider="geocoder", ttl=86400)
    if not isinstance(data, list):
        raise RouteError("Không đọc được kết quả tìm địa chỉ.", 503, "geocoder_unavailable")
    results = []
    for row in data[:5]:
        try:
            results.append({"label": str(row["display_name"])[:400], "point": coordinate([row["lat"], row["lon"]])})
        except (KeyError, TypeError, RouteError):
            continue
    return jsonify(results=results)


@bp.get("/api/rain-route")
def rain_route():
    start, end = coordinate(request.args.get("start", "")), coordinate(request.args.get("end", ""))
    vehicle = request.args.get("vehicle", "motorcycle")
    if vehicle not in ("motorcycle", "car"):
        raise RouteError("Phương tiện phải là Xe máy hoặc Ô tô.")
    separation = distance(start, end)
    if separation < .05 or separation > 500:
        raise RouteError("Hai điểm cần cách nhau ít nhất 50m và tối đa 500km theo đường thẳng.")
    departure = departure_time(request.args.get("departure"))
    if not _capacity.acquire(blocking=False):
        raise RouteError("Đang có nhiều yêu cầu tìm đường. Vui lòng thử lại sau.", 429, "routing_busy")
    try:
        return jsonify(find_routes(start, end, vehicle, departure))
    finally:
        _capacity.release()


def init_rain_routes(app, load_stations, load_forecast):
    for name, default in {"VALHALLA_URL": "https://valhalla1.openstreetmap.de", "OPEN_METEO_URL": "https://api.open-meteo.com/v1/forecast",
                          "GEOCODER_URL": "https://nominatim.openstreetmap.org/search", "ROUTING_USER_AGENT": "HeatWatch/1.0 (IoT weather route planner)"}.items():
        app.config.setdefault(name, os.getenv(name, default))
    app.extensions["route_heat"] = (load_stations, load_forecast)
    app.register_blueprint(bp)
