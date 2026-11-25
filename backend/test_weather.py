from datetime import datetime, timezone
import unittest
from unittest.mock import patch

from .app import app
from .rain_routes import RouteError
from .weather import normalize_weather


def upstream_weather():
    # 23:45 at UTC+7, so the hourly strip crosses the local date boundary.
    hour = int(datetime(2026, 11, 21, 16, tzinfo=timezone.utc).timestamp())
    return {
        "utc_offset_seconds": 25200,
        "current": {
            "time": hour + 2700, "temperature_2m": 28.3,
            "relative_humidity_2m": 77, "weather_code": 0, "is_day": 0,
        },
        "hourly": {
            "time": [hour, hour + 3600, hour + 7200],
            "temperature_2m": [29.2, 28.1, None],
            "relative_humidity_2m": [74, 79],
            "precipitation_probability": [90, 0, None],
            "weather_code": [3, 0, 95],
            "is_day": [0, 0, 0],
        },
    }


class WeatherTests(unittest.TestCase):
    @patch("backend.weather.http_json", return_value=upstream_weather())
    def test_public_endpoint_rounds_location_and_returns_local_hourly_data(self, fetch):
        response = app.test_client().get("/api/weather?point=10.76432,106.68321")
        self.assertEqual(response.status_code, 200)
        params = fetch.call_args.kwargs["params"]
        self.assertEqual((params["latitude"], params["longitude"]), ("10.76", "106.68"))
        self.assertIn("precipitation_probability", params["hourly"])
        data = response.get_json()
        self.assertEqual(data["source"], "Open-Meteo")
        self.assertEqual(data["current"]["icon"], "night")
        self.assertEqual(data["current"]["time"], "2026-11-21T23:45+07:00")
        self.assertEqual(data["current"]["rain_until"], "2026-11-22T00:00+07:00")
        self.assertEqual(data["current"]["rain_probability"], 0)
        self.assertEqual(len(data["hourly"]), 2)
        self.assertEqual(data["hourly"][1]["icon"], "storm")
        for field in ("temperature", "humidity", "rain_probability"):
            self.assertIsNone(data["hourly"][1][field])

    @patch("backend.weather.http_json")
    def test_invalid_coordinates_are_rejected_before_fetch(self, fetch):
        result = app.test_client().get("/api/weather?point=nan,106.7")
        self.assertEqual(result.status_code, 400)
        fetch.assert_not_called()

    @patch("backend.weather.http_json", return_value=upstream_weather())
    def test_current_view_only_requests_the_rain_window(self, fetch):
        response = app.test_client().get("/api/weather?point=10.78,106.70&current_only=1")
        self.assertEqual(response.status_code, 200)
        params = fetch.call_args.kwargs["params"]
        self.assertEqual(params["hourly"], "precipitation_probability")
        self.assertEqual(params["forecast_hours"], 2)
        data = response.get_json()
        self.assertNotIn("hourly", data)
        self.assertEqual(data["current"]["rain_probability"], 0)

    @patch("backend.weather.http_json", side_effect=RouteError("timeout", 503))
    def test_upstream_failure_remains_separate_from_station_data(self, _fetch):
        result = app.test_client().get("/api/weather?point=10.78,106.7")
        self.assertEqual(result.status_code, 503)
        self.assertEqual(result.get_json()["code"], "weather_unavailable")

    def test_missing_nearest_hour_does_not_borrow_later_rain_probability(self):
        upstream = upstream_weather()
        upstream["hourly"]["time"][1] = None
        data = normalize_weather(upstream)
        self.assertIsNone(data["current"]["rain_probability"])
        self.assertNotIn("rain_until", data["current"])
