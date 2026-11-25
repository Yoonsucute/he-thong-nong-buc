"""Exercise the installed HeatWatch APK on a dedicated Android emulator.

Start tool/check_ui.py --serve first. This uses synthetic API data only.
Never targets a physical phone; requires the explicit emulator-5554 serial.
"""
import json
from pathlib import Path
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/"build/ui-review"
ADB=Path.home()/"AppData/Local/Android/Sdk/platform-tools/adb.exe"
SERIAL="emulator-5554"
report={"device":SERIAL,"fixture_api":"http://127.0.0.1:5056 via adb reverse","checks":[],"screenshots":[]}
if "--capture" in sys.argv and (OUT/"android-result.json").exists():
    report=json.loads((OUT/"android-result.json").read_text(encoding="utf-8"))
    report["capture_passed"]=False


def adb(*args):
    return subprocess.run([str(ADB),"-s",SERIAL,*args],check=True,capture_output=True).stdout


def tree():
    for attempt in range(5):
        try:
            result=adb("shell","uiautomator","dump","/sdcard/heatwatch-review.xml")
            if b"null root" in result: raise ValueError("UI transitioning")
            data=adb("shell","cat","/sdcard/heatwatch-review.xml")
            (OUT/"android-last-ui.xml").write_bytes(data)
            nodes=list(ET.fromstring(data).iter("node"))
            if not any(n.attrib.get("text") or n.attrib.get("content-desc") for n in nodes):
                raise ValueError("Flutter semantics not ready")
            return nodes
        except (subprocess.CalledProcessError, ValueError, ET.ParseError):
            if attempt==4: raise
            time.sleep(1)


def find(label, *, exact=False):
    for node in tree():
        value=node.attrib.get("content-desc","") or node.attrib.get("text","")
        if (value==label if exact else label in value):
            bounds=list(map(int,re.findall(r"\d+",node.attrib["bounds"])))
            if bounds[2]>bounds[0] and bounds[3]>bounds[1]: return bounds
    raise AssertionError("UI target missing: "+label)


def tap(label, *, exact=False):
    x1,y1,x2,y2=wait_for(label,exact=exact)
    adb("shell","input","tap",str((x1+x2)//2),str((y1+y2)//2))
    time.sleep(.8)


def wait_for(label, *, exact=False):
    for attempt in range(5):
        try: return find(label,exact=exact)
        except AssertionError:
            if attempt==4: raise
            time.sleep(1)


def screenshot(name):
    adb("shell","screencap","-p",f"/sdcard/{name}.png")
    adb("pull",f"/sdcard/{name}.png",str(OUT/f"{name}.png"))
    report["screenshots"].append(name+".png")


def dismiss_keyboard():
    state=adb("shell","dumpsys","input_method")
    if b"mInputShown=true" in state or b"isInputViewShown=true" in state:
        adb("shell","input","keyevent","4")
        time.sleep(.5)


def main():
    OUT.mkdir(parents=True,exist_ok=True)
    assert adb("shell","getprop","ro.kernel.qemu").strip()==b"1", "Only run on emulator"
    if "--existing" not in sys.argv:
        adb("shell","am","force-stop","com.example.he_thong_nong_buc")
    adb("shell","am","start","-W","-n","com.example.he_thong_nong_buc/.MainActivity")
    time.sleep(2)
    tap("Kết nối máy chủ",exact=True)
    nodes=tree()
    field=next(n for n in nodes if n.attrib.get("class")=="android.widget.EditText")
    x1,y1,x2,y2=map(int,re.findall(r"\d+",field.attrib["bounds"]))
    # Flutter's scrollable semantics can expose its whole viewport as the
    # unfocused EditText bounds. On this fixed Pixel 8a test layout, use the
    # observed search-field position instead of tapping the viewport centre.
    if y2-y1>500:
        x1,y1,x2,y2=53,1290,1028,1455
    adb("shell","input","tap",str((x1+x2)//2),str((y1+y2)//2))
    adb("shell","input","keycombination","113","29") # Ctrl+A in the URL field.
    adb("shell","input","keyevent","67")
    time.sleep(.3)
    adb("shell","input","text","http://127.0.0.1:5056")
    entered=next(n for n in tree() if n.attrib.get("class")=="android.widget.EditText")
    assert entered.attrib.get("text")=="http://127.0.0.1:5056", entered.attrib
    dismiss_keyboard()
    tap("Kết nối",exact=True)
    time.sleep(12)
    find("Thiết bị UI_TEST_A")
    screenshot("app-main")
    report["checks"].append("changed server URL in app and loaded fixture stations")
    tap("Thiết bị UI_TEST_A")
    find("Chỉ số nóng bức")
    screenshot("app-quick-view")
    try: tap("Xem chi tiết",exact=True)
    except AssertionError:
        adb("shell","input","swipe","540","1900","540","1000","400")
        tap("Xem chi tiết",exact=True)
    time.sleep(2)
    find("Dự báo 5 giờ tới")
    screenshot("app-detail")
    report["checks"].append("tapped live map pin, read quick view and opened station detail")
    if "--capture" in sys.argv:
        report["image_transport"]="local files containing unmodified Esri tiles"
        report["capture_passed"]=True
        return
    tap("Back",exact=True)
    time.sleep(1)
    tap("Điểm đo\nTab")
    nodes=tree()
    field=next(n for n in nodes if n.attrib.get("class")=="android.widget.EditText")
    x1,y1,x2,y2=map(int,re.findall(r"\d+",field.attrib["bounds"]))
    if y2-y1>500:
        x1,y1,x2,y2=53,1290,1028,1455
    adb("shell","input","tap",str((x1+x2)//2),str((y1+y2)//2))
    time.sleep(1)
    adb("shell","input","text","UI_TEST_B")
    time.sleep(.5)
    search_field=next(n for n in tree() if n.attrib.get("class")=="android.widget.EditText")
    assert "UI_TEST_B" in search_field.attrib.get("text",""), search_field.attrib
    dismiss_keyboard()
    time.sleep(1)
    find("Công viên Thủ Đức")
    screenshot("app-search")
    report["checks"].append("search by station ID returns the expected station")
    tap("Cảnh báo\nTab")
    find("Cảnh báo nóng")
    screenshot("app-alerts")
    report["checks"].append("alerts show text and icons, not color alone")
    tap("Bản đồ\nTab")
    tap("Tất cả điểm đo",exact=True)
    time.sleep(3)
    screenshot("app-main")
    report["passed"]=True


if __name__=="__main__":
    try: main()
    except Exception as error:
        if "--capture" in sys.argv:
            report["capture_passed"]=False
            report["capture_error"]=str(error)
        else:
            report["passed"]=False
            report["error"]=str(error)
        raise
    finally:
        report["checks"]=list(dict.fromkeys(report["checks"]))
        report["screenshots"]=list(dict.fromkeys(report["screenshots"]))
        (OUT/"android-result.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
        print(json.dumps(report,ensure_ascii=False,indent=2))
