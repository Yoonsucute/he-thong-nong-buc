"""Deterministic routing/weather boundary tests; no external API calls."""
from datetime import datetime, timedelta, timezone
import json
from unittest import TestCase
from unittest.mock import patch

from . import app as api
from . import rain_routes as rr


def encode(points):
    output, last = [], [0, 0]
    for point in points:
        for axis, value in enumerate(point):
            value = round(value * 1e6)
            delta = value - last[axis]
            last[axis] = value
            delta = ~(delta << 1) if delta < 0 else delta << 1
            while delta >= 32:
                output.append(chr((32 | (delta & 31)) + 63))
                delta >>= 5
            output.append(chr(delta + 63))
    return "".join(output)


def trip(points, length=5, seconds=(300, 300)):
    return {"status": 0, "summary": {"length": length, "time": sum(seconds)},
            "legs": [{"shape": encode(points), "maneuvers": [
                {"begin_shape_index": i, "end_shape_index": i + 1, "time": duration}
                for i, duration in enumerate(seconds)]}]}


class RainRoutesTests(TestCase):
    def setUp(self):
        config = patch.dict(api.app.config, TESTING=True)
        config.start()
        self.addCleanup(config.stop)
        providers = patch.dict(api.app.extensions, route_heat=(lambda: [], lambda station: []))
        providers.start()
        self.addCleanup(providers.stop)
        self.client = api.app.test_client()
        self.departure = datetime(2026, 11, 16, 3, 30, tzinfo=timezone.utc)
        self.short = trip([[10, 106], [10.002, 106], [10.004, 106]], 5, (300, 300))
        self.dry = trip([[10, 106], [10.05, 106], [10.004, 106]], 8, (720, 180))

    def test_polyline6_roundtrip_negative_and_invalid_shapes(self):
        points = [[10.123456, 106.654321], [-10.25, -106.5], [0, 0]]
        self.assertEqual(rr.decode_shape(encode(points)), points)
        for encoded in ("", "~", "\n", "???"):
            with self.assertRaises((ValueError, rr.RouteError)):
                rr.decode_shape(encoded)

    def test_maneuver_timing_and_segment_coverage(self):
        route = rr.unpack_trip(trip([[10, 106], [10.01, 106], [10.02, 106]], seconds=(30, 870)))
        self.assertAlmostEqual(route["elapsed"][1], 30)
        self.assertAlmostEqual(route["elapsed"][-1], 900)
        segments = rr.samples_for_route(route, self.departure)
        self.assertEqual(segments[0]["start_index"], 0)
        self.assertEqual(segments[-1]["end_index"], len(route["geometry"]) - 1)
        self.assertAlmostEqual(sum(s["duration_seconds"] for s in segments), 900)
        self.assertTrue(all(a["end_index"] == b["start_index"] for a, b in zip(segments, segments[1:])))
        self.assertTrue(all(self.departure < datetime.fromisoformat(s["passed_at"]) < self.departure + timedelta(seconds=900) for s in segments))

    def test_sampling_is_bounded_even_for_long_routes(self):
        route = {"geometry": [[10 + i / 1000, 106] for i in range(1001)], "elapsed": [i * 50 for i in range(1001)],
                 "distance_km": 500, "duration_seconds": 50000}
        self.assertLessEqual(len(rr.samples_for_route(route, self.departure)), 24)

    def test_weather_uses_interval_ending_after_passage_and_utc(self):
        start = self.departure.replace(minute=0).timestamp()
        hourly = {"time": [start, start + 3600, start + 7200], "precipitation_probability": [0, 90, 10], "precipitation": [0, 3, 0]}
        # 10:30 Vietnam = 03:30 UTC: the 03:00-04:00 rain interval ends at 04:00.
        weather = rr.weather_at(hourly, "2026-11-16T10:30:00+07:00")
        self.assertEqual(weather["probability_percent"], 90)
        self.assertEqual(weather["risk"], "high")
        self.assertEqual(weather["forecast_hour"], "2026-11-16T04:00:00+00:00")
        self.assertIsNone(rr.weather_at(hourly, "2026-11-16T07:30:00+00:00"))

    def test_missing_invalid_and_out_of_order_weather_remains_unknown(self):
        now = self.departure.timestamp()
        for hourly in ({}, {"time": [now], "precipitation_probability": [None], "precipitation": [0]},
                       {"time": [now], "precipitation_probability": [10], "precipitation": [None]},
                       {"time": ["bad"]}, {"time": None}, {"time": [now, now - 3600]}):
            self.assertIsNone(rr.weather_at(hourly, self.departure.isoformat()))

    def fake_services(self, incomplete=False):
        trips = iter([self.short, self.dry, self.short])
        def response(url, *, params=None, payload=None, provider, ttl=300):
            if provider == "valhalla":
                return {"trip": next(trips)}
            if params.get("timezone") == "auto":
                return {"timezone": "Asia/Ho_Chi_Minh"}
            latitudes = [float(value) for value in params["latitude"].split(",")]
            hour = self.departure.replace(minute=0).timestamp()
            return [{"hourly": {"time": [hour + i * 3600 for i in range(4)],
                                "precipitation_probability": [None if incomplete else (90 if lat < 10.01 else 0)] * 4,
                                "precipitation": [0] * 4, "temperature_2m": [27] * 4,
                                "relative_humidity_2m": [55] * 4}} for lat in latitudes]
        return response

    def test_rain_recommendation_can_differ_from_shortest_and_deduplicates(self):
        with api.app.app_context(), patch.object(rr, "http_json", side_effect=self.fake_services()) as upstream:
            result = rr.find_routes([10, 106], [10.004, 106], "motorcycle", self.departure)
        self.assertEqual(len(result["routes"]), 2)
        self.assertEqual(result["shortest_route_id"], "route-1")
        self.assertEqual(result["recommended_route_id"], "route-2")
        self.assertEqual(result["lowest_risk_route_id"], "route-2")
        self.assertLess(result["routes"][1]["expected_rain_minutes"], result["routes"][0]["expected_rain_minutes"])
        requests = [call.kwargs["payload"] for call in upstream.call_args_list if call.kwargs["provider"] == "valhalla"]
        self.assertEqual(len(requests), 3)
        for payload in requests:
            self.assertEqual(payload["costing"], "motor_scooter")
            self.assertEqual(payload["date_time"], {"type": 1, "value": "2026-11-16T10:30"})
            self.assertNotIn("alternates", payload)
            self.assertEqual(payload["costing_options"]["motor_scooter"]["top_speed"], 60)

    def test_partial_forecast_never_produces_a_dry_recommendation(self):
        with api.app.app_context(), patch.object(rr, "http_json", side_effect=self.fake_services(incomplete=True)):
            result = rr.find_routes([10, 106], [10.004, 106], "car", self.departure)
        self.assertIsNone(result["recommended_route_id"])
        self.assertIsNone(result["lowest_risk_route_id"])
        self.assertEqual(result["shortest_route_id"], "route-1")
        self.assertTrue(result["warnings"])
        for route in result["routes"]:
            self.assertIsNone(route["rain_score"])
            self.assertIsNone(route["expected_rain_minutes"])
            self.assertEqual(route["weather_coverage_percent"], 0)
            self.assertTrue(all(s["risk"] == "unknown" for s in route["segments"]))

    def test_weather_outage_preserves_route_but_does_not_recommend(self):
        route = rr.unpack_trip(self.short)
        with api.app.app_context(), patch.object(rr, "http_json", side_effect=rr.RouteError("down", 503)):
            warning = rr.assess_routes([route], self.departure)
        self.assertTrue(warning)
        self.assertFalse(route["weather_complete"])
        self.assertIsNone(route["rain_score"])
        self.assertTrue(route["geometry"])

    def test_car_uses_origin_timezone_including_dst(self):
        def service(url, *, params=None, payload=None, provider, ttl=300):
            if params and params.get("timezone") == "auto":
                return {"timezone": "America/New_York"}
            self.assertEqual(payload["date_time"]["value"], "2026-11-15T22:30")
            self.assertEqual(payload["costing"], "auto")
            return {"trip": self.short}
        with api.app.app_context(), patch.object(rr, "http_json", side_effect=service), patch.object(rr, "assess_routes"):
            # Supply a completed assessment without invoking another provider.
            def assess(routes, departure):
                for route in routes:
                    route.update(weather_complete=True, combined_exposure_minutes=0)
            with patch.object(rr, "assess_routes", side_effect=assess):
                result = rr.find_routes([10, 106], [10.004, 106], "car", self.departure)
        self.assertEqual(len(result["routes"]), 1)
        self.assertEqual(result["shortest_route_id"], result["recommended_route_id"])

    def test_public_read_endpoint_and_input_limits_before_upstream(self):
        params = {"start": "10,106", "end": "10.1,106.1", "vehicle": "car"}
        with patch.object(rr, "find_routes", return_value={"routes": []}) as finder:
            self.assertEqual(self.client.get("/api/rain-route", query_string=params).status_code, 200)
            finder.assert_called_once()
        invalid = [{"start": "nan,106"}, {"end": "91,106"}, {"end": "10,106"}, {"end": "0,0"},
                   {"vehicle": "truck"}, {"departure": "not-a-date"}, {"departure": "2000-01-01T10:00+07:00"},
                   {"departure": (rr.utc_now() + timedelta(days=7)).isoformat()}]
        with patch.object(rr, "http_json") as upstream:
            for changes in invalid:
                self.assertEqual(self.client.get("/api/rain-route", query_string=params | changes).status_code, 400, changes)
            upstream.assert_not_called()

    def test_geocoding_returns_choices_and_coordinates_without_login(self):
        with patch.object(rr, "http_json", return_value=[{"display_name": "Test address", "lat": "10", "lon": "106"}]) as upstream:
            response = self.client.get("/api/rain-route/geocode", query_string={"q": "Test address"})
            self.assertEqual(response.status_code, 200)
            self.assertEqual(response.json["results"][0]["point"], [10, 106])
            self.assertEqual(upstream.call_args.kwargs["provider"], "geocoder")
        with patch.object(rr, "http_json") as upstream:
            self.assertEqual(self.client.get("/api/rain-route/geocode?q=10,106").status_code, 200)
            self.assertEqual(self.client.get("/api/rain-route/geocode?q=x").status_code, 400)
            upstream.assert_not_called()

    def test_provider_timeout_is_a_controlled_error_and_cache_is_reused(self):
        with api.app.app_context(), patch.object(rr, "urlopen", side_effect=TimeoutError):
            with self.assertRaises(rr.RouteError) as error:
                rr.http_json("https://example.invalid/test-timeout", provider="weather")
            self.assertEqual(error.exception.status, 503)
        with api.app.app_context(), patch.object(rr, "urlopen") as upstream:
            upstream.return_value.__enter__.return_value.read.return_value = json.dumps({"ok": True}).encode()
            first = rr.http_json("https://example.invalid/cache-test", provider="weather")
            first["ok"] = False
            second = rr.http_json("https://example.invalid/cache-test", provider="weather")
            self.assertEqual(second, {"ok": True})
            upstream.assert_called_once()

    def long_route(self):
        return {"geometry": [[10, 106], [10.054, 106]], "elapsed": [0, 900],
                "distance_km": 6, "duration_seconds": 900}

    def station(self, key, latitude, heat=39, seconds_old=30, online=True):
        stamp = (self.departure - timedelta(seconds=seconds_old)).isoformat()
        return {"device_id": key, "name": "Trạm " + key,
                "latitude": latitude, "longitude": 106, "enabled": True, "is_online": online,
                "location_source": "gps", "location_status": "current", "location_updated_at": stamp, "gps_valid": True,
                "latest": {"created_at": stamp, "temperature": 32, "humidity": 78, "heat_index": heat,
                           "latitude": latitude, "longitude": 106, "location_source": "gps", "location_updated_at": stamp, "gps_valid": True}}

    def test_sparse_shape_is_split_and_live_station_only_covers_nearby_segment(self):
        live = self.station("LIVE", 10.009)
        stale = self.station("STALE", 10.027, seconds_old=121)
        offline = self.station("OFFLINE", 10.045, online=False)
        route = self.long_route()
        with api.app.app_context(), patch.dict(api.app.extensions, route_heat=(lambda: [live, stale, offline], lambda station: [])), \
                patch.object(rr, "utc_now", return_value=self.departure), patch.object(rr, "http_json", side_effect=self.fake_services()):
            rr.assess_routes([route], self.departure)
        self.assertEqual(len(route["geometry"]), 4)
        first, middle, last = route["segments"]
        self.assertEqual([s["heat_source"] for s in (first, middle, last)], ["esp32", "open_meteo", "open_meteo"])
        self.assertEqual(first["station_id"], "LIVE")
        self.assertEqual((first["temperature"], first["humidity"], first["heat_index"]), (32, 78, 39))
        self.assertEqual(first["risk"], "high")
        self.assertEqual(round(route["heat_source_percent"]["esp32"], 1), 33.3)
        self.assertEqual(route["max_rain_probability"], 90)

    def test_scheduled_route_uses_bounded_lstm_and_open_meteo_if_missing(self):
        north, south = self.station("N", 10.009), self.station("S", 10.045)
        route = self.long_route()
        hour = self.departure.replace(minute=0)
        forecast = [{"time": (hour + timedelta(hours=i)).isoformat(), "heat_index": 36 + i} for i in range(1, 6)]

        def station_forecast(station):
            return forecast if station["device_id"] == "N" else []

        # Same-hour weather, but far enough beyond the 15-minute measurement window.
        departure = self.departure + timedelta(hours=1)
        with api.app.app_context(), patch.dict(api.app.extensions, route_heat=(lambda: [north, south], station_forecast)), \
                patch.object(rr, "utc_now", return_value=self.departure), patch.object(rr, "http_json", side_effect=self.fake_services()):
            warning = rr.assess_routes([route], departure)
        first, middle, last = route["segments"]
        self.assertEqual([s["heat_source"] for s in (first, middle, last)], ["lstm", "open_meteo", "open_meteo"])
        self.assertEqual(first["station_id"], "N")
        self.assertIsNone(first["temperature"])
        self.assertIn("LSTM", warning)

    def test_score_balances_duration_distance_and_exposure(self):
        routes = [
            {"distance_km": 5, "duration_seconds": 300, "combined_exposure_minutes": 2},
            {"distance_km": 15, "duration_seconds": 1500, "combined_exposure_minutes": 0},
            {"distance_km": 7, "duration_seconds": 480, "combined_exposure_minutes": .7},
        ]
        recommended, shortest, lowest = rr.rank_routes(routes)
        self.assertIs(shortest, routes[0])
        self.assertIs(lowest, routes[1])
        self.assertIs(recommended, routes[2])

    def test_open_meteo_timezone_failure_does_not_hide_valhalla_routes(self):
        def service(url, *, provider, params=None, payload=None, ttl=300):
            if provider != "valhalla":
                raise rr.RouteError("offline", 503)
            self.assertNotIn("date_time", payload)
            return {"trip": self.short}
        with api.app.app_context(), patch.object(rr, "http_json", side_effect=service):
            result = rr.find_routes([10, 106], [10.004, 106], "car", self.departure)
        self.assertEqual(result["shortest_route_id"], "route-1")
        self.assertIsNone(result["recommended_route_id"])
        self.assertTrue(any("múi giờ" in warning for warning in result["warnings"]))
