"""Contract tests dùng DB/mô hình giả lập trong bộ kiểm thử, không kết nối MQTT."""
from datetime import datetime, timedelta
from decimal import Decimal
from unittest import TestCase, main
from unittest.mock import MagicMock, patch

from backend import app as api
from backend.ml.ml_service import ForecastUnavailable, run_lstm_forecast
from backend.ml import ml_service


class ApiTests(TestCase):
    def test_location_only_first_fix_registers_without_fake_reading(self):
        self.cursor.fetchone.return_value = None
        payload = dict(device_id="NEW_LBS", latitude=21.5, longitude=105.4,
                       location_source="lbs", location_age_s=0, location_pending=False)
        api.on_message(None, None, MagicMock(payload=api.json.dumps(payload).encode()))
        calls = [call.args for call in self.cursor.execute.call_args_list]
        self.assertTrue(any("INSERT INTO devices" in sql for sql, *_ in calls))
        self.assertFalse(any("INSERT INTO sensor_logs" in sql for sql, *_ in calls))
        self.assertIn(("UPDATE devices SET location_pending=%s WHERE device_id=%s", (False, "NEW_LBS")), calls)
        self.connection.commit.assert_called_once()

    def test_failed_fix_retains_recent_location_and_marks_last_known(self):
        device = self.saved_device() | dict(location_source="lbs", location_pending=False)
        self.cursor.fetchone.return_value = device
        payload = dict(device_id="A", temperature=30, humidity=70, location_pending=True)
        api.on_message(None, None, MagicMock(payload=api.json.dumps(payload).encode()))
        self.assertTrue(any(call.args == ("UPDATE devices SET location_pending=%s WHERE device_id=%s", (True, "A"))
                            for call in self.cursor.execute.call_args_list))
        location = api.location_json(device | dict(location_pending=True))
        self.assertEqual(location["location_status"], "last_known")
        self.assertEqual(location["latitude"], device["latitude"])
        self.assertEqual(location["location_updated_at"], api.iso_datetime(device["location_updated_at"]))

    def setUp(self):
        from .admin_auth import credential_tag
        config_patch = patch.dict(api.app.config, TESTING=True, SECRET_KEY="api-test-secret",
                                 ADMIN_USER="test-admin", ADMIN_PASSWORD_HASH="test-only-hash")
        config_patch.start()
        self.addCleanup(config_patch.stop)
        self.client = api.app.test_client()
        with api.app.app_context():
            tag = credential_tag()
        with self.client.session_transaction() as auth_session:
            auth_session.update(admin_user="test-admin", admin_tag=tag, csrf_token="api-test-csrf")
        self.client.environ_base["HTTP_X_CSRF_TOKEN"] = "api-test-csrf"
        self.connection = MagicMock()
        self.cursor = self.connection.cursor.return_value.__enter__.return_value
        self.db_patch = patch.object(api, "get_db_connection", return_value=self.connection)
        self.db_patch.start()
        self.addCleanup(self.db_patch.stop)
        self.now = datetime.now(api.LOCAL_TZ).replace(tzinfo=None, microsecond=0)

    def reading(self, device="ESP32_01", **updates):
        value = dict(id=1, device_id=device, temperature=Decimal("30.5"), humidity=Decimal("70"),
                     heat_index=Decimal("34.5"), latitude=10.7, longitude=106.7, created_at=self.now)
        value.update(updates)
        return value

    def test_latest_filters_single_device_and_serializes_decimal_time(self):
        self.cursor.fetchone.return_value = self.reading()
        response = self.client.get("/api/sensor/latest?device_id=ESP32_01")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["heat_index"], 34.5)
        self.assertEqual(response.json["warning_level"], "caution")
        self.assertTrue(response.json["created_at"].endswith("+07:00"))
        sql, params = self.cursor.execute.call_args.args
        self.assertIn("device_id = %s", sql)
        self.assertEqual(params, ["ESP32_01"])
        self.connection.close.assert_called_once()

    def test_missing_latest_is_not_zero_reading(self):
        self.cursor.fetchone.return_value = None
        response = self.client.get("/api/sensor/latest?device_id=ESP32_01")
        self.assertEqual(response.status_code, 404)
        self.assertEqual(response.json["code"], "no_data")

    def test_history_is_chronological_and_filters_range(self):
        self.cursor.fetchall.return_value = [self.reading(id=2), self.reading(id=1, created_at=self.now-timedelta(minutes=1))]
        response = self.client.get("/api/sensor/history?device_id=ESP32_01&limit=40&start=2026-01-01T00:00:00&end=2026-12-31T23:59:59")
        self.assertEqual(response.status_code, 200)
        self.assertEqual([row["id"] for row in response.json], [1, 2])
        sql, params = self.cursor.execute.call_args.args
        self.assertIn("created_at >= %s", sql)
        self.assertIn("created_at <= %s", sql)
        self.assertEqual(params[0], "ESP32_01")
        self.assertEqual(params[-1], 40)

    def test_bad_query_validation_runs_before_database(self):
        for path in ("/api/sensor/history?limit=0", "/api/sensor/history?limit=oops",
                     "/api/sensor/history?start=no-date", "/api/sensor/history?device_id=x%27%20OR%201=1",
                     "/api/sensor/history?start=2026-02-01&end=2026-01-01"):
            with self.subTest(path=path):
                response = self.client.get(path)
                self.assertEqual(response.status_code, 400)
        self.connection.cursor.assert_not_called()

    def test_device_list_has_all_stations_and_freshness(self):
        self.cursor.fetchall.side_effect = [
            [dict(device_id="A", name="Điểm A", enabled=1, latitude=10, longitude=106),
             dict(device_id="B", name="Điểm B", enabled=0, latitude=None, longitude=None),
             dict(device_id="C", name="Điểm C", enabled=1, latitude=11, longitude=107)],
            [self.reading("A"), self.reading("B", created_at=self.now-timedelta(hours=3))],
        ]
        response = self.client.get("/api/devices")
        self.assertEqual(response.status_code, 200)
        self.assertTrue(response.json[0]["is_online"])
        self.assertFalse(response.json[1]["is_online"])
        self.assertIsNone(response.json[2]["latest"])

    def test_create_validates_location_and_no_nan(self):
        valid = dict(device_id="A", name="Điểm A", latitude=10, longitude=106, enabled=True)
        for change in (dict(latitude=91), dict(longitude="NaN"), dict(latitude=None), dict(enabled="true")):
            with self.subTest(change=change):
                response = self.client.post("/api/devices", json=valid | change)
                self.assertEqual(response.status_code, 400)
        self.connection.cursor.assert_not_called()

    def test_create_device_and_duplicate_conflict(self):
        self.cursor.fetchone.return_value = None
        payload = dict(device_id="A", name="Điểm A", latitude=10, longitude=106)
        self.assertEqual(self.client.post("/api/devices", json=payload).status_code, 201)
        self.connection.commit.assert_called_once()
        self.cursor.fetchone.return_value = dict(device_id="A")
        self.assertEqual(self.client.post("/api/devices", json=payload).status_code, 409)

    def test_archive_keeps_logs(self):
        self.cursor.fetchone.return_value = dict(device_id="A")
        response = self.client.delete("/api/devices/A")
        self.assertEqual(response.status_code, 200)
        statements = [call.args[0] for call in self.cursor.execute.call_args_list]
        self.assertTrue(any("UPDATE devices SET enabled=FALSE" in sql for sql in statements))
        self.assertFalse(any("DELETE" in sql for sql in statements))

    def test_update_device_preserves_id(self):
        response = self.client.put("/api/devices/A", json={"device_id": "B"})
        self.assertEqual(response.status_code, 400)
        self.cursor.fetchone.return_value = dict(device_id="A", name="A", latitude=10, longitude=106, enabled=1)
        response = self.client.put("/api/devices/A", json={"name": "Trạm A"})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["device_id"], "A")
        self.assertEqual(response.json["name"], "Trạm A")

    def hourly(self):
        latest_hour = self.now.replace(minute=0, second=0)
        return [dict(hour=latest_hour-timedelta(hours=i), temperature=30, humidity=70) for i in range(12)]

    def test_forecast_requires_twelve_contiguous_hourly_inputs(self):
        with patch.object(api, "run_lstm_forecast") as model:
            self.cursor.fetchall.return_value = self.hourly()[:11]
            self.cursor.fetchone.return_value = self.reading()
            self.assertEqual(self.client.get("/api/sensor/forecast?device_id=A").status_code, 422)
            rows = self.hourly()
            rows[5]["hour"] -= timedelta(minutes=30)
            self.cursor.fetchall.return_value = rows
            self.assertEqual(self.client.get("/api/sensor/forecast?device_id=A").status_code, 422)
            model.assert_not_called()

    def test_forecast_is_device_specific_and_exactly_five_hour_timestamps(self):
        self.cursor.fetchall.return_value = self.hourly()
        self.cursor.fetchone.return_value = self.reading("A")
        with patch.object(api, "run_lstm_forecast", return_value=[30, 31, 32, 33, 34]) as model:
            response = self.client.get("/api/sensor/forecast?device_id=A")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["model_status"], "experimental")
        self.assertEqual(len(response.json["hourly"]), 5)
        stamps = [datetime.fromisoformat(row["time"]) for row in response.json["hourly"]]
        self.assertEqual(stamps[1]-stamps[0], timedelta(hours=1))
        model.assert_called_once()
        for call in self.cursor.execute.call_args_list:
            self.assertEqual(call.args[1], ("A",))
        self.assertIn("AVG(temperature)", self.cursor.execute.call_args_list[0].args[0])

    def test_model_unavailable_does_not_return_fake_prediction(self):
        self.cursor.fetchall.return_value = self.hourly()
        self.cursor.fetchone.return_value = self.reading("A")
        with patch.object(api, "run_lstm_forecast", side_effect=ForecastUnavailable("Không có mô hình")):
            response = self.client.get("/api/sensor/forecast?device_id=A")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json["code"], "model_unavailable")
        self.assertNotIn("forecast_next_5_hours", response.json)

    def test_stale_inputs_are_not_forecast_as_current(self):
        self.cursor.fetchall.return_value = self.hourly()
        self.cursor.fetchone.return_value = self.reading("A", created_at=self.now-timedelta(hours=3))
        response = self.client.get("/api/sensor/forecast?device_id=A")
        self.assertEqual(response.status_code, 422)
        self.assertEqual(response.json["code"], "stale_data")

    def test_alerts_include_only_threshold_crossing_readings(self):
        self.cursor.fetchall.return_value = [self.reading(heat_index=40), self.reading(heat_index=None, temperature=15, humidity=40)]
        response = self.client.get("/api/alerts?device_id=A")
        self.assertEqual(response.status_code, 200)
        self.assertEqual(len(response.json), 1)
        self.assertEqual(response.json[0]["warning_level"], "danger")

    def test_database_error_response_and_cleanup(self):
        self.cursor.execute.side_effect = api.pymysql.OperationalError(2006, "Disconnected")
        response = self.client.get("/api/sensor/latest")
        self.assertEqual(response.status_code, 503)
        self.assertEqual(response.json["code"], "database_unavailable")
        self.connection.rollback.assert_called_once()
        self.connection.close.assert_called_once()

    def test_mqtt_disabled_station_and_invalid_payload_do_not_insert(self):
        self.cursor.fetchone.return_value = dict(device_id="A", enabled=0)
        msg = MagicMock(payload=b'{"device_id":"A","temperature":30,"humidity":70}')
        api.on_message(None, None, msg)
        self.assertEqual(self.cursor.execute.call_count, 1)
        self.connection.commit.assert_not_called()

    def mqtt_reading_parameters(self, payload, device):
        self.cursor.fetchone.return_value = device
        api.on_message(None, None, MagicMock(payload=api.json.dumps(payload).encode("utf-8")))
        inserts = [call for call in self.cursor.execute.call_args_list
                   if "INSERT INTO sensor_logs" in call.args[0]]
        self.assertEqual(len(inserts), 1)
        self.connection.commit.assert_called_once()
        return inserts[0].args[1]

    def saved_device(self):
        return dict(device_id="A", enabled=1, latitude=10.5, longitude=106.7,
                    location_source="manual", location_updated_at=self.now-timedelta(minutes=5))

    def test_mqtt_no_coordinates_retains_complete_saved_position(self):
        payload = dict(device_id="A", temperature=30, humidity=70)
        device = self.saved_device()
        values = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(values[:3], ("A", 30.0, 70.0))
        self.assertEqual(values[4:6], (10.5, 106.7))
        self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_mqtt_partial_coordinates_never_mix_with_saved_position(self):
        for partial in (dict(latitude=21.5), dict(longitude=105.4)):
            with self.subTest(partial=partial):
                self.cursor.reset_mock()
                self.connection.reset_mock()
                payload = dict(device_id="A", temperature=30, humidity=70) | partial
                device = self.saved_device()
                with self.assertLogs(api.app.logger, level="WARNING") as logs:
                    values = self.mqtt_reading_parameters(payload, device)
                self.assertEqual(values[4:6], (10.5, 106.7))
                self.assertTrue(any("MQTT A" in line for line in logs.output))
                self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_mqtt_invalid_coordinates_keep_measurement_and_saved_position(self):
        invalid = ((None, None), (None, 105.4), (21.5, None), (91, 105.4),
                   (21.5, -181), ("NaN", 105.4), (21.5, "Infinity"), ("bad", "bad"), (True, 105.4))
        for latitude, longitude in invalid:
            with self.subTest(latitude=latitude, longitude=longitude):
                self.cursor.reset_mock()
                self.connection.reset_mock()
                payload = dict(device_id="A", temperature=30, humidity=70,
                               latitude=latitude, longitude=longitude)
                device = self.saved_device()
                with self.assertLogs(api.app.logger, level="WARNING"):
                    values = self.mqtt_reading_parameters(payload, device)
                self.assertEqual(values[:3], ("A", 30.0, 70.0))
                self.assertEqual(values[4:6], (10.5, 106.7))
                self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_mqtt_new_device_without_coordinates_has_no_invented_position(self):
        payload = dict(device_id="NEW", temperature=30, humidity=70)
        values = self.mqtt_reading_parameters(payload, None)
        self.assertEqual(values[4:6], (None, None))
        created = [call for call in self.cursor.execute.call_args_list if "INSERT INTO devices" in call.args[0]]
        self.assertEqual(created[0].args[1], ("NEW", "NEW", None, None, "unknown", None))

    def test_mqtt_valid_coordinate_pair_updates_device_and_measurement(self):
        payload = dict(device_id="A", temperature=30, humidity=70, latitude=21.5,
                       longitude=105.4, location_source="gnss")
        device = dict(device_id="A", enabled=1, latitude=10.5, longitude=106.7)
        values = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(values[4:6], (21.5, 105.4))
        updated = [call for call in self.cursor.execute.call_args_list if "UPDATE devices" in call.args[0]]
        self.assertEqual(updated[0].args[1][:3], (21.5, 105.4, "gnss"))
        self.assertEqual(updated[0].args[1][-1], "A")

    def test_atgm336h_fix_replaces_lbs_and_persists_gps_metadata(self):
        payload = dict(device_id="A", temperature=30, humidity=70, latitude=21.5,
                       longitude=105.4, location_source="ATGM336H", gps_valid=True, satellites=8)
        device = self.saved_device() | dict(location_source="lbs", location_pending=False)
        values = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(values[4:6], (21.5, 105.4))
        self.assertEqual((values[7], *values[9:]), ("gps", True, 8))
        self.cursor.execute.assert_any_call(
            "UPDATE devices SET gps_valid=%s,satellites=%s,gps_reported_at=%s WHERE device_id=%s",
            (True, 8, values[6], "A"))

    def test_atgm336h_no_fix_preserves_saved_position_and_timestamp(self):
        payload = dict(device_id="A", temperature=30, humidity=70, latitude=0, longitude=0,
                       location_source="NONE", gps_valid=False, satellites=0)
        device = self.saved_device() | dict(location_source="gps", location_pending=False)
        with self.assertLogs(api.app.logger, level="WARNING"):
            values = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(values[4:6], (10.5, 106.7))
        self.assertEqual(values[7:], ("gps", device["location_updated_at"], False, 0))
        self.cursor.execute.assert_any_call("UPDATE devices SET location_pending=%s WHERE device_id=%s",
                                            (True, "A"))
        self.assertFalse(any("UPDATE devices SET latitude" in call.args[0]
                             for call in self.cursor.execute.call_args_list))

    def test_mqtt_lbs_cannot_replace_confirmed_gps(self):
        payload = dict(device_id="A", temperature=30, humidity=70, latitude=21.5,
                       longitude=105.4, location_source="lbs")
        device = self.saved_device() | dict(location_source="gps", location_pending=False)
        values = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(values[4:6], (10.5, 106.7))
        self.assertEqual(values[7], "gps")
        self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_gps_rejects_zero_pair_and_missing_fix_flag(self):
        fix = dict(location_source="GPS", gps_valid=True, latitude=0, longitude=0)
        self.assertIsNone(api.incoming_location(fix, api.current_time(), is_gps=True))
        self.assertIsNone(api.incoming_location(fix | dict(latitude=21, gps_valid="true"),
                                                api.current_time(), is_gps=True))
        self.assertEqual(api.location_json(fix | dict(location_source="gps",
            location_updated_at=self.now))["location_status"], "unavailable")

    def test_mqtt_incomplete_saved_position_is_not_used_as_fallback(self):
        payload = dict(device_id="A", temperature=30, humidity=70, longitude=105.4)
        device = dict(device_id="A", enabled=1, latitude=10.5, longitude=None)
        with self.assertLogs(api.app.logger, level="WARNING"):
            values = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(values[4:6], (None, None))
        self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_lbs_cached_fix_time_does_not_advance_with_each_measurement(self):
        received_at = self.now.replace(tzinfo=api.LOCAL_TZ)
        payload = dict(device_id="A", temperature=30, humidity=70,
                       latitude=10.5, longitude=106.7, location_source="lbs", location_age_s=30)
        device = dict(device_id="A", enabled=1, latitude=10.5, longitude=106.7)
        with patch.object(api, "current_time", return_value=received_at):
            first = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(first[7], "lbs")
        self.assertEqual(first[8], self.now-timedelta(seconds=30))
        self.assertEqual(first[6]-first[8], timedelta(seconds=30))

        self.cursor.reset_mock()
        self.connection.reset_mock()
        payload["location_age_s"] = 45
        with patch.object(api, "current_time", return_value=received_at+timedelta(seconds=15)):
            repeated = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(repeated[8], first[8])
        self.assertEqual(repeated[6]-first[6], timedelta(seconds=15))

    def test_mqtt_missing_coordinates_preserves_saved_location_metadata(self):
        fixed_at = self.now-timedelta(minutes=5)
        device = dict(device_id="A", enabled=1, latitude=10.5, longitude=106.7,
                      location_source="lbs", location_updated_at=fixed_at)
        values = self.mqtt_reading_parameters(dict(device_id="A", temperature=30, humidity=70), device)
        self.assertEqual(values[4:6], (10.5, 106.7))
        self.assertEqual(values[7:9], ("lbs", fixed_at))
        self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_mqtt_invalid_location_metadata_keeps_position_and_measurement(self):
        bad_metadata = [dict(location_age_s=value) for value in (-1, 601, "NaN", None, True)]
        bad_metadata += [dict(location_source=value) for value in ("manual", "ip", None, [])]
        fixed_at = self.now-timedelta(minutes=2)
        device = dict(device_id="A", enabled=1, latitude=10.5, longitude=106.7,
                      location_source="gnss", location_updated_at=fixed_at)
        for metadata in bad_metadata:
            with self.subTest(metadata=metadata):
                self.cursor.reset_mock()
                self.connection.reset_mock()
                payload = dict(device_id="A", temperature=30, humidity=70, latitude=21.5,
                               longitude=105.4, location_source="lbs", location_age_s=0) | metadata
                with self.assertLogs(api.app.logger, level="WARNING"):
                    values = self.mqtt_reading_parameters(payload, device)
                self.assertEqual(values[:3], ("A", 30.0, 70.0))
                self.assertEqual(values[4:6], (10.5, 106.7))
                self.assertEqual(values[7:9], ("gnss", fixed_at))
                self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_manual_coordinates_set_fix_time_but_name_only_edit_preserves_it(self):
        fixed_at = self.now-timedelta(minutes=8)
        self.cursor.fetchone.return_value = dict(device_id="A", name="A", enabled=1,
            latitude=10.5, longitude=106.7, location_source="lbs", location_updated_at=fixed_at)
        response = self.client.put("/api/devices/A", json={"name": "Tên mới", "enabled": False})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["location_source"], "lbs")
        self.assertEqual(response.json["location_updated_at"], api.iso_datetime(fixed_at))
        values = self.cursor.execute.call_args.args[1]
        self.assertEqual(values[4:6], ("lbs", fixed_at))

        received_at = self.now.replace(tzinfo=api.LOCAL_TZ)
        with patch.object(api, "current_time", return_value=received_at):
            response = self.client.put("/api/devices/A", json={"latitude": 21.5, "longitude": 105.4})
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["location_source"], "manual")
        self.assertEqual(response.json["location_updated_at"], api.iso_datetime(self.now))
        values = self.cursor.execute.call_args.args[1]
        self.assertEqual(values[1:3], (21.5, 105.4))
        self.assertEqual(values[4:6], ("manual", self.now))

    def test_manual_create_marks_location_but_partial_coordinate_edit_is_rejected(self):
        self.cursor.fetchone.return_value = None
        response = self.client.post("/api/devices", json=dict(device_id="A", latitude=10.5, longitude=106.7))
        self.assertEqual(response.status_code, 201)
        self.assertEqual(response.json["location_source"], "manual")
        self.assertTrue(response.json["location_updated_at"].endswith("+07:00"))
        self.cursor.fetchone.return_value = dict(device_id="A", name="A", enabled=1,
                                                latitude=10.5, longitude=106.7)
        self.cursor.execute.reset_mock()
        response = self.client.put("/api/devices/A", json={"latitude": 21.5})
        self.assertEqual(response.status_code, 400)
        self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_admin_form_with_unchanged_coordinates_does_not_refresh_lbs_fix(self):
        fixed_at = self.now-timedelta(minutes=8)
        self.cursor.fetchone.return_value = dict(device_id="A", name="A", enabled=1,
            latitude=10.5, longitude=106.7, location_source="lbs", location_updated_at=fixed_at)
        response = self.client.put("/api/devices/A", json=dict(name="Tên mới", enabled=True,
            latitude=10.5, longitude=106.7))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["location_source"], "lbs")
        self.assertEqual(response.json["location_updated_at"], api.iso_datetime(fixed_at))

    def test_renaming_device_with_unknown_location_does_not_invent_a_fix(self):
        self.cursor.fetchone.return_value = dict(device_id="A", name="A", enabled=1,
            latitude=None, longitude=None, location_source="unknown", location_updated_at=None)
        response = self.client.put("/api/devices/A", json={"name": "ESP32 chưa định vị"})
        self.assertEqual(response.status_code, 200)
        self.assertIsNone(response.json["latitude"])
        self.assertIsNone(response.json["longitude"])
        self.assertIsNone(response.json["location_updated_at"])

    def test_location_metadata_is_serialized_in_device_and_reading_responses(self):
        fixed_at = self.now-timedelta(seconds=90)
        self.cursor.fetchall.side_effect = [[dict(device_id="A", name="A", enabled=1,
            latitude=10.5, longitude=106.7, location_source="lbs", location_updated_at=fixed_at)],
            [self.reading("A", location_source="lbs", location_updated_at=fixed_at)]]
        response = self.client.get("/api/devices")
        self.assertEqual(response.status_code, 200)
        device = response.json[0]
        self.assertEqual(device["location_source"], "lbs")
        self.assertEqual(device["location_updated_at"], api.iso_datetime(fixed_at))
        self.assertEqual(device["latest"]["location_updated_at"], api.iso_datetime(fixed_at))
        self.assertNotEqual(device["last_seen"], device["location_updated_at"])

    def test_legacy_sample_coordinates_are_hidden_in_device_and_latest_reading(self):
        legacy = dict(device_id="ESP32_01", name="ESP32_01", enabled=1,
                      latitude=10.7769, longitude=106.7009,
                      location_source="unknown", location_updated_at=None)
        sample = self.reading(latitude=10.7769, longitude=106.7009,
                              location_source="unknown", location_updated_at=None)
        self.cursor.fetchall.side_effect = [[legacy], [sample]]
        response = self.client.get("/api/devices")
        self.assertEqual(response.status_code, 200)
        for location in (response.json[0], response.json[0]["latest"]):
            self.assertIsNone(location["latitude"])
            self.assertIsNone(location["longitude"])
            self.assertIsNone(location["location_updated_at"])
            self.assertEqual(location["location_status"], "unavailable")
        # Serializing an old row must not rewrite or discard its database data.
        self.assertEqual(sample["latitude"], 10.7769)
        self.assertEqual(legacy["longitude"], 106.7009)
        self.connection.commit.assert_not_called()

    def test_unknown_sample_is_not_exposed_by_latest_or_history_routes(self):
        sample = self.reading(latitude=10.7769, longitude=106.7009)
        self.cursor.fetchone.return_value = sample
        latest = self.client.get("/api/sensor/latest?device_id=ESP32_01")
        self.assertEqual(latest.json["location_status"], "unavailable")
        self.assertIsNone(latest.json["latitude"])
        self.cursor.fetchall.return_value = [sample]
        history = self.client.get("/api/sensor/history?device_id=ESP32_01")
        self.assertEqual(history.json[0]["location_status"], "unavailable")
        self.assertIsNone(history.json[0]["longitude"])

    def test_location_requires_a_valid_source_pair_and_fix_time(self):
        cases = [dict(location_source="unknown", location_updated_at=self.now),
                 dict(location_source="gnss", location_updated_at=None),
                 dict(location_source="lbs", location_updated_at="bad-time"),
                 dict(location_source="gnss", location_updated_at=self.now, latitude=91),
                 dict(location_source="gnss", location_updated_at=self.now+timedelta(seconds=31))]
        now = self.now.replace(tzinfo=api.LOCAL_TZ)
        for changes in cases:
            with self.subTest(changes=changes):
                location = api.location_json(self.reading(**changes), now)
                self.assertEqual(location["location_status"], "unavailable")
                self.assertIsNone(location["latitude"])
                self.assertIsNone(location["longitude"])

    def test_lbs_manual_gnss_and_last_known_are_explicitly_distinguished(self):
        now = self.now.replace(tzinfo=api.LOCAL_TZ)
        cases = [("manual", 86400, "manual"), ("lbs", 600, "estimated"),
                 ("lbs", 601, "last_known"), ("gnss", 120, "current"),
                 ("gnss", 121, "last_known")]
        for source, age, expected in cases:
            with self.subTest(source=source, age=age):
                value = api.location_json(self.reading(location_source=source,
                    location_updated_at=self.now-timedelta(seconds=age)), now)
                self.assertEqual(value["location_status"], expected)
                self.assertEqual(value["latitude"], 10.7)
                self.assertEqual(value["longitude"], 106.7)

    def test_mqtt_does_not_copy_legacy_default_coordinates_into_new_readings(self):
        device = dict(device_id="A", enabled=1, latitude=10.7769, longitude=106.7009,
                      location_source="unknown", location_updated_at=None)
        values = self.mqtt_reading_parameters(dict(device_id="A", temperature=30, humidity=70), device)
        self.assertEqual(values[4:6], (None, None))
        self.assertEqual(values[7:9], ("unknown", None))
        self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_unattributed_incoming_coordinates_do_not_replace_a_trusted_fix(self):
        device = self.saved_device()
        payload = dict(device_id="A", temperature=30, humidity=70,
                       latitude=10.7769, longitude=106.7009)
        with self.assertLogs(api.app.logger, level="WARNING"):
            values = self.mqtt_reading_parameters(payload, device)
        self.assertEqual(values[4:6], (10.5, 106.7))
        self.assertEqual(values[7:9], ("manual", device["location_updated_at"]))
        self.assertFalse(any("UPDATE devices" in call.args[0] for call in self.cursor.execute.call_args_list))

    def test_manual_confirmation_can_attribute_a_previous_unknown_coordinate_pair(self):
        self.cursor.fetchone.return_value = dict(device_id="A", name="A", enabled=1,
            latitude=10.7769, longitude=106.7009, location_source="unknown", location_updated_at=None)
        response = self.client.put("/api/devices/A", json=dict(latitude=10.7769, longitude=106.7009))
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json["location_source"], "manual")
        self.assertEqual(response.json["location_status"], "manual")
        self.assertIsNotNone(response.json["location_updated_at"])

    def test_additive_migration_adds_only_missing_metadata_columns(self):
        # Real SQL is inspected through a mock; the user's database is untouched.
        self.cursor.fetchall.side_effect = [
            [{"Field": "device_id"}, {"Field": "location_source"}],
            [{"Field": "device_id"}],
        ]
        with patch.object(api, "_schema_ready", False):
            api.ensure_schema(self.connection)
        statements = [call.args[0] for call in self.cursor.execute.call_args_list]
        alterations = [sql for sql in statements if sql.startswith("ALTER TABLE")]
        self.assertEqual(len(alterations), 8)
        self.assertFalse(any("ALTER TABLE devices ADD COLUMN location_source" in sql for sql in alterations))
        self.assertTrue(any("ALTER TABLE devices ADD COLUMN location_updated_at" in sql for sql in alterations))
        self.assertTrue(any("ALTER TABLE sensor_logs ADD COLUMN gps_valid" in sql for sql in alterations))
        self.assertFalse(any(sql.startswith("UPDATE sensor_logs") for sql in statements))

    def test_existing_metadata_columns_do_not_trigger_alter_or_timestamp_backfill(self):
        self.cursor.fetchall.return_value = [{"Field": "device_id"}, {"Field": "location_source"},
                                            {"Field": "location_updated_at"}, {"Field": "gps_valid"},
                                            {"Field": "satellites"}, {"Field": "gps_reported_at"}]
        with patch.object(api, "_schema_ready", False):
            api.ensure_schema(self.connection)
        statements = [call.args[0] for call in self.cursor.execute.call_args_list]
        self.assertFalse(any(sql.startswith("ALTER TABLE") for sql in statements))
        self.assertFalse(any(sql.startswith("UPDATE") for sql in statements))

    def test_legacy_zero_index_is_preserved(self):
        self.assertEqual(api.reading_json(self.reading(heat_index=0))["heat_index"], 0)

    def test_model_rejects_short_series_instead_of_padding(self):
        with self.assertRaises(ForecastUnavailable):
            run_lstm_forecast([dict(temperature=30, humidity=70)] * 11)

    def test_model_uses_hourly_mean_index_in_chronological_order(self):
        import numpy as np
        model, scaler = MagicMock(), MagicMock()
        scaler.transform.side_effect = lambda values: values
        scaler.inverse_transform.side_effect = lambda values: values
        model.predict.return_value = np.asarray([[30, 31, 32, 33, 34]])
        rows = [dict(temperature=30, humidity=70, heat_index=40-index) for index in range(12)]
        with patch.object(ml_service, "model", model), patch.object(ml_service, "scaler", scaler):
            self.assertEqual(run_lstm_forecast(rows), [30, 31, 32, 33, 34])
        inputs = scaler.transform.call_args.args[0].reshape(-1).tolist()
        self.assertEqual(inputs, list(range(29, 41)))
        self.assertEqual(scaler.inverse_transform.call_args.args[0].shape, (5, 1))

    def test_mqtt_reading_publishes_realtime_alert_only_when_above_threshold(self):
        self.cursor.fetchone.return_value = dict(
            device_id="ESP32_01", name="Trạm Bách Khoa", enabled=1,
            latitude=None, longitude=None, location_source="unknown",
            location_updated_at=None, location_pending=1,
        )
        self.cursor.lastrowid = 99
        published = []
        with patch.object(api, "publish_realtime_alert", side_effect=published.append):
            safe_msg = MagicMock(payload=b'{"device_id":"ESP32_01","temperature":26.0,"humidity":55.0}')
            api.on_message(None, None, safe_msg)
            self.assertEqual(published, [])
            hot_msg = MagicMock(payload=b'{"device_id":"ESP32_01","temperature":35.0,"humidity":70.0}')
            api.on_message(None, None, hot_msg)
        self.assertEqual(len(published), 1)
        self.assertEqual(published[0]["device_id"], "ESP32_01")
        self.assertEqual(published[0]["device_name"], "Trạm Bách Khoa")
        self.assertGreaterEqual(published[0]["heat_index"], 38)
        self.assertEqual(published[0]["warning_level"], "danger")

    def test_alerts_stream_sse_emits_connected_and_realtime_alert(self):
        response = self.client.get("/api/alerts/stream")
        self.assertEqual(response.status_code, 200)
        self.assertIn("text/event-stream", response.mimetype)
        stream = response.response
        first_chunk = next(stream)
        self.assertIn(b"event: connected", first_chunk)
        api.publish_realtime_alert({"id": 7, "device_id": "ESP32_01", "heat_index": 35.5, "warning_level": "caution"})
        second_chunk = next(stream)
        self.assertIn(b"event: alert", second_chunk)
        self.assertIn(b'"heat_index": 35.5', second_chunk)
        response.close()

    def test_train_pipeline_cleans_builds_windows_and_computes_mae_rmse_r2(self):
        from .ml import train_model
        df = train_model.generate_synthetic_hourly(days=3, seed=7)
        hourly = train_model.clean_and_resample_hourly(df)
        X, y = train_model.build_contiguous_windows(hourly)
        self.assertEqual(X.shape[1], 12)
        self.assertEqual(y.shape[1], 5)
        self.assertGreater(len(X), 40)
        y_true = [[30.0, 31.0, 32.0, 33.0, 34.0], [32.0, 33.0, 34.0, 35.0, 36.0]]
        y_pred = [[30.5, 31.0, 31.5, 33.0, 34.5], [32.0, 33.5, 34.0, 34.5, 36.0]]
        metrics = train_model.evaluate_predictions(y_true, y_pred)
        self.assertIn("mae", metrics["overall"])
        self.assertIn("rmse", metrics["overall"])
        self.assertIn("r2", metrics["overall"])
        self.assertEqual(len(metrics["per_horizon"]), 5)
        self.assertGreater(metrics["overall"]["r2"], 0.9)

    def test_model_metrics_endpoint_handles_missing_and_valid_report(self):
        with patch.object(api.Path, "is_file", return_value=False):
            missing = self.client.get("/api/model/metrics")
            self.assertEqual(missing.status_code, 200)
            self.assertFalse(missing.json["available"])
        sample = '{"source":"mysql","metrics":{"overall":{"mae":0.5,"rmse":0.7,"r2":0.95},"per_horizon":[]}}'
        with patch.object(api.Path, "is_file", return_value=True), \
                patch.object(api.Path, "read_text", return_value=sample):
            ok = self.client.get("/api/model/metrics")
            self.assertEqual(ok.status_code, 200)
            self.assertTrue(ok.json["available"])
            self.assertEqual(ok.json["metrics"]["overall"]["r2"], 0.95)

if __name__ == "__main__":
    main()
