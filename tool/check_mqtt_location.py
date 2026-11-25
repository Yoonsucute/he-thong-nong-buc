"""Real broker -> app callback -> isolated MySQL -> HTTP regression check.

Run from the project directory: python tool/check_mqtt_location.py
Uses synthetic test coordinates only; never uploads firmware or touches iot_db.
Leaves the uniquely named test database and JSON evidence for inspection.
"""
import json
import os
from pathlib import Path
import sys
import threading
import time
from urllib.request import urlopen
from uuid import uuid4

import paho.mqtt.client as mqtt
import pymysql
from werkzeug.serving import make_server

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def main():
    suffix = uuid4().hex[:10]
    db_name = "heatwatch_location_test_" + suffix
    # Only create a new test database; never delete or rewrite an existing one.
    connection = pymysql.connect(host=os.getenv("DB_HOST", "localhost"),
        port=int(os.getenv("DB_PORT", "3306")), user=os.getenv("DB_USER", "root"),
        password=os.getenv("DB_PASSWORD", "root"))
    with connection.cursor() as cursor:
        cursor.execute(f"CREATE DATABASE `{db_name}` CHARACTER SET utf8mb4")
    connection.close()
    os.environ["DB_NAME"] = db_name
    from backend import app as api

    api.MQTT_TOPIC = "heatwatch/test/location/" + suffix
    subscribed = threading.Event()
    receiver = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="hw-sub-" + suffix)
    sender = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="hw-pub-" + suffix)
    receiver.on_connect = api.on_connect
    receiver.on_message = api.on_message
    receiver.on_subscribe = lambda *args: subscribed.set()
    api.mqtt_client = receiver
    server = make_server("127.0.0.1", 0, api.app, threaded=True)
    url = f"http://127.0.0.1:{server.server_port}"
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    report = dict(database=db_name, topic=api.MQTT_TOPIC, api_url=url,
                  synthetic=True, hardware_verified=False, stages=[])
    try:
        receiver.connect(api.MQTT_BROKER, api.MQTT_PORT)
        receiver.loop_start()
        assert subscribed.wait(15), "MQTT subscription not acknowledged"
        sender.connect(api.MQTT_BROKER, api.MQTT_PORT)
        sender.loop_start()
        thread.start()

        def devices():
            with urlopen(url + "/api/devices", timeout=10) as response:
                return json.load(response)

        assert devices() == []  # Clients can already be open before power-on.
        report["stages"].append(dict(name="before_power_on", devices=[]))
        base = dict(device_id="TEST_AUTO_" + suffix, temperature=31.2, humidity=65)

        def stage(name, message, check):
            start = time.monotonic()
            info = sender.publish(api.MQTT_TOPIC, json.dumps(message), qos=1)
            info.wait_for_publish(timeout=10)
            assert info.is_published(), "MQTT publish not acknowledged"
            while time.monotonic() - start < 20:
                rows = devices()
                if len(rows) == 1 and check(rows[0]):
                    elapsed = round(time.monotonic() - start, 3)
                    report["stages"].append(dict(name=name, mqtt_to_api_seconds=elapsed, devices=rows))
                    print(f"PASS {name}: MQTT -> MySQL -> HTTP {elapsed}s", flush=True)
                    return rows[0]
                time.sleep(.1)
            raise AssertionError("Stage timed out: " + name)

        stage("waiting_for_fix", base | dict(location_pending=True),
              lambda d: d["latitude"] is None and d["location_pending"])
        # Deliberately synthetic points used only on the isolated test topic/DB.
        fix = base | dict(latitude=21.5, longitude=105.4, location_source="lbs",
                          location_age_s=0, location_pending=False)
        first = stage("first_lbs_fix", fix,
                      lambda d: d["latitude"] == 21.5 and d["location_status"] == "estimated")
        moved = stage("same_id_moves_one_pin", fix | dict(latitude=21.6, longitude=105.5),
              lambda d: d["latitude"] == 21.6 and d["longitude"] == 105.5)
        saved = stage("failed_fix_keeps_last_location", base | dict(location_pending=True),
                     lambda d: d["latitude"] == 21.6 and d["location_status"] == "last_known")
        assert saved["location_updated_at"] == moved["location_updated_at"]
        # Even a failed sensor can deliver the next fix independently.
        stage("location_only_without_sensor", dict(device_id=base["device_id"],
              latitude=21.7, longitude=105.6, location_source="lbs", location_age_s=0),
              lambda d: d["latitude"] == 21.7 and not d["location_pending"])
        with api.database() as connection, connection.cursor() as cursor:
            cursor.execute("SELECT COUNT(*) AS n FROM devices")
            assert cursor.fetchone()["n"] == 1
            cursor.execute("SELECT COUNT(*) AS n FROM sensor_logs")
            assert cursor.fetchone()["n"] == 4
        report["passed"] = True
    finally:
        sender.disconnect()
        receiver.disconnect()
        sender.loop_stop()
        receiver.loop_stop()
        if thread.is_alive():
            server.shutdown()
        server.server_close()
        output = ROOT / "build" / "location-check" / "mqtt-result.json"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print("Evidence: " + str(output), flush=True)


if __name__ == "__main__":
    main()
