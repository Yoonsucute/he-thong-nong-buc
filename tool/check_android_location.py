"""Real permission/settings dialogs on emulator-5554 only; synthetic GPS fix.

Resets HeatWatch location-flow preferences and permission flags. For a release
APK (run-as disabled), resets this app's local data on the dedicated emulator.
Tests off/skip/retry/on/deny, then leaves the app open with a synthetic fix.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "build/android-location-review"
ADB = Path(os.environ["LOCALAPPDATA"]) / "Android/Sdk/platform-tools/adb.exe"
SERIAL = "emulator-5554"
PACKAGE = "com.example.he_thong_nong_buc"


def adb(*args, check=True):
    return subprocess.run([str(ADB), "-s", SERIAL, *args], check=check, capture_output=True).stdout


def tree():
    output = adb("shell", "uiautomator", "dump", "/sdcard/heatwatch-location-test.xml", check=False)
    if b"dumped" not in output:
        return [] # Do not read a stale XML snapshot while Android is transitioning.
    try:
        return list(ET.fromstring(adb("shell", "cat", "/sdcard/heatwatch-location-test.xml")).iter("node"))
    except (ET.ParseError, subprocess.CalledProcessError):
        return []


def label(node):
    return node.get("text", "") or node.get("content-desc", "")


def wait_for(text, package=None, attempts=10, fix=False):
    for _ in range(attempts):
        if fix:
            adb("emu", "geo", "fix", "106.7009", "10.7769")
        nodes = tree()
        matches = [node for node in nodes if text in label(node) and (package is None or node.get("package") == package)]
        if matches:
            exact = [node for node in matches if label(node) == text]
            return (exact or matches)[-1]
        time.sleep(.6)
    raise AssertionError(f"UI not found: {text}; last labels: {[label(n) for n in nodes if label(n)][:15]}")


def tap(text, package=None):
    node = wait_for(text, package)
    x1, y1, x2, y2 = map(int, re.findall(r"\d+", node.get("bounds")))
    adb("shell", "input", "tap", str((x1+x2)//2), str((y1+y2)//2))


def screenshot(name):
    (OUT / name).write_bytes(adb("exec-out", "screencap", "-p"))


def stop():
    adb("shell", "am", "force-stop", PACKAGE)


def start():
    # Permission revocation can asynchronously kill an existing UID. Let that
    # finish before launch, then wait for Android's first activity transition.
    time.sleep(2)
    for _ in range(3):
        result = subprocess.run([str(ADB), "-s", SERIAL, "shell", "am", "start", "--ez", "enable-impeller", "false", "-n", PACKAGE + "/.MainActivity"], capture_output=True, timeout=20)
        if result.returncode == 0:
            return
        time.sleep(2)
    raise RuntimeError(f"Android launch failed: {result.stdout!r} {result.stderr!r}")


def reset_flow():
    # A SettingsClient resolution belongs to Play services, so stopping the app
    # alone does not necessarily close a leftover dialog from a prior test.
    if any(n.get("package") == "com.google.android.gms" and label(n) == "No thanks" for n in tree()):
        adb("shell", "input", "keyevent", "4")
    stop()
    try:
        adb("shell", "run-as", PACKAGE, "rm", "-f", "shared_prefs/location_flow.xml", "shared_prefs/location_flow.xml.bak")
    except subprocess.CalledProcessError:
        # Release APKs are not debuggable. Only this test app's local cache and
        # preference flags are reset; project MySQL/sensors are never touched.
        assert b"Success" in adb("shell", "pm", "clear", PACKAGE)


def reset_permissions():
    for permission in ("android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION"):
        adb("shell", "pm", "revoke", PACKAGE, permission, check=False)
        adb("shell", "pm", "clear-permission-flags", PACKAGE, permission, "user-set", "user-fixed", check=False)


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "device": SERIAL, "real_android_dialogs": True, "gps_fix_simulated": True, "checks": []}
    try:
        if "--resume-after-denial" not in sys.argv:
            reset_flow()
            reset_permissions()
            adb("shell", "cmd", "location", "set-location-enabled", "true")
            start()
            wait_for("Don’t allow", "com.google.android.permissioncontroller")
            screenshot("permission-while-using.png")
            tap("Don’t allow", "com.google.android.permissioncontroller")
        wait_for("Bạn chưa cấp quyền", PACKAGE)
        screenshot("permission-denied.png")
        assert not any(n.get("package") == "com.google.android.gms" for n in tree())
        time.sleep(3)
        assert not any(n.get("package") == "com.google.android.permissioncontroller" for n in tree())
        report["checks"].append("denied: native permission rejection keeps map/manual route available without another prompt")
        # Continue in this Activity to avoid graphics-driver instability during
        # repeated process destruction on Windows emulator hosts.
        adb("shell", "cmd", "location", "set-location-enabled", "false")
        tap("Định vị tôi", PACKAGE)
        wait_for("While using the app", "com.google.android.permissioncontroller")
        tap("While using the app", "com.google.android.permissioncontroller")
        wait_for("Turn on", "com.google.android.gms")
        screenshot("system-location-off.png")
        assert adb("shell", "cmd", "location", "is-location-enabled").strip() == b"false"
        report["checks"].append("location off: actual Android while-in-use permission followed by Google Play services Turn on/No thanks dialog")
        tap("No thanks", "com.google.android.gms")
        wait_for("Đã để sau", PACKAGE)
        screenshot("settings-declined.png")
        assert adb("shell", "cmd", "location", "is-location-enabled").strip() == b"false"
        time.sleep(3)
        wait_for("Đã để sau", PACKAGE)
        assert not any(n.get("package") in ("com.google.android.gms", "com.google.android.permissioncontroller") for n in tree())
        report["checks"].append("skip: location remains off and manual entry remains available without reopening system dialog")
        tap("Định vị tôi", PACKAGE)
        wait_for("Turn on", "com.google.android.gms")
        screenshot("system-retry.png")
        tap("Turn on", "com.google.android.gms")
        wait_for("Độ chính xác khoảng", PACKAGE, attempts=10, fix=True)
        wait_for("Vị trí của bạn", PACKAGE)
        assert adb("shell", "cmd", "location", "is-location-enabled").strip() == b"true"
        screenshot("enabled-blue-position.png")
        report["checks"].append("retry: system Turn on enables device location; synthetic GPS yields native blue position and accuracy")
        assert not any(n.get("package") in ("com.google.android.gms", "com.google.android.permissioncontroller") for n in tree())
        tap("Định vị tôi", PACKAGE)
        wait_for("Độ chính xác khoảng", PACKAGE, attempts=10, fix=True)
        wait_for("Vị trí của bạn", PACKAGE)
        report["checks"].append("location already on/granted: explicit retry acquires fix without permission/settings dialog")
        tap("Tìm đường tránh nóng bức và hạn chế mưa", PACKAGE)
        adb("shell", "input", "swipe", "540", "1900", "540", "1000", "400")
        # Flutter field semantics expose the manual form even after denial.
        wait_for("Điểm đi", PACKAGE)
        assert any(n.get("class") == "android.widget.EditText" for n in tree())
        wait_for("Vị trí của tôi", PACKAGE)
        screenshot("native-route-origin.png")
        report["checks"].append("native rain-route form automatically defaults editable origin to current GPS without pressing Use my location or searching")
        adb("shell", "input", "swipe", "540", "900", "540", "1900", "400")
        screenshot("final-native-map.png")
        report["passed"] = True
    finally:
        (OUT / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(report, ensure_ascii=True, indent=2))


if __name__ == "__main__":
    main()
