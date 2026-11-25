"""Headless Chrome checks against the real web UI and an isolated fixture API.

No database, MQTT, real sensor data, or user's browser profile is used.
Requires: python -m pip install --target build/ui-test-deps playwright
"""
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta, timezone
import json
import logging
import math
from pathlib import Path
import sys
import threading
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/ui-test-deps"))
sys.path.insert(0, str(ROOT))
from flask import Flask, jsonify, render_template, request, send_file
from werkzeug.serving import make_server

OUT = ROOT / "build/ui-review"
OUT.mkdir(parents=True, exist_ok=True)
app = Flask(__name__, template_folder=str(ROOT / "backend/templates"), static_folder=str(ROOT / "backend/static"))
from backend.admin_auth import init_admin_auth
init_admin_auth(app)
app.config["SECRET_KEY"] = "isolated-ui-fixture-secret"
now = datetime.now(timezone(timedelta(hours=7)))


def stamp(seconds=20):
    return (datetime.now(timezone(timedelta(hours=7))) - timedelta(seconds=seconds)).isoformat(timespec="seconds")


def device(index, name, lat, lon, heat, online=True):
    return dict(device_id=f"UI_TEST_{index}", name=name, enabled=True, is_online=online,
        latitude=lat, longitude=lon, location_source="lbs", location_updated_at=stamp(60),
        location_status="estimated" if online else "last_known", location_pending=not online,
        last_seen=stamp(20 if online else 1800),
        latest=dict(device_id=f"UI_TEST_{index}", temperature=31.2, humidity=67.5,
                    heat_index=heat, created_at=stamp(20 if online else 1800)))


devices = [device("A", "Trạm Sân trường", 10.7769, 106.7009, 35.6),
    device("B", "Công viên Thủ Đức", 10.85, 106.76, 39.2),
    device("C", "Khu dân cư Bình An", 10.72, 106.65, 30.1, False),
    dict(device_id="UI_TEST_D", name="Trạm đang khởi động", enabled=True, is_online=False,
         latitude=None, longitude=None, location_status="unavailable", location_pending=True, latest=None)]


@app.get("/")
def website():
    # This isolated fixture exercises all management controls; production / is public.
    return render_template("index.html", admin_view=True)


@app.route("/api/devices", methods=["GET", "POST"])
def api_devices():
    if request.method == "POST":
        body = request.get_json()
        devices.append(body | dict(is_online=False, location_source="manual", location_updated_at=stamp(), latest=None))
        return jsonify(devices[-1]), 201
    for target in devices:
        if target.get("is_online"):
            target["last_seen"]=stamp(20)
            target["location_updated_at"]=stamp(60)
            if target.get("latest"): target["latest"]["created_at"]=stamp(20)
    return jsonify(devices)


@app.get("/test-tiles/<int:z>/<int:y>/<int:x>")
def test_tiles(z,y,x):
    path=ROOT/"build/map-review/tiles"/str(z)/str(x)/f"{y}.jpg"
    if not path.exists():
        data=urlopen(f"https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",timeout=20).read()
        path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(data)
    return send_file(path,mimetype="image/jpeg")


@app.route("/api/devices/<device_id>", methods=["PUT", "DELETE"])
def api_device(device_id):
    target = next(d for d in devices if d["device_id"] == device_id)
    target.update(request.get_json() if request.method == "PUT" else dict(enabled=False))
    return jsonify(target)


@app.get("/api/sensor/history")
def history():
    return jsonify([dict(id=i, device_id=request.args.get("device_id"), temperature=30+i*.1,
        humidity=65+i*.2, heat_index=32+i*.35, created_at=stamp((10-i)*600)) for i in range(10)])


@app.get("/api/sensor/forecast")
def forecast():
    if request.args.get("device_id") == "UI_TEST_D":
        return jsonify(error="Cần đủ 12 giờ dữ liệu liên tiếp của điểm đo để dự báo 5 giờ tiếp theo.", code="insufficient_data"), 422
    return jsonify(forecast_next_5_hours=[35.8, 36.4, 37.1, 36.2, 35.0],
        hourly=[dict(time=(now+timedelta(hours=i+1)).isoformat(), heat_index=h)
                for i, h in enumerate([35.8, 36.4, 37.1, 36.2, 35.0])],
        generated_at=now.isoformat(), warning_level="caution", model_status="experimental",
        model_note="Mô hình thử nghiệm · Cần đánh giá bằng dữ liệu thực tế.")


@app.get("/api/alerts")
def alerts():
    return jsonify([d["latest"] for d in devices if d.get("latest") and d["latest"]["heat_index"] >= 32])


def prepare_assets():
    # Byte-identical vendor assets: exercise the production HTML without CDN
    # availability making layout checks nondeterministic.
    urls = ["https://cdn.jsdelivr.net/npm/bootstrap@5.3.8/dist/css/bootstrap.min.css",
        "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css", "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js",
        "https://cdn.jsdelivr.net/npm/chart.js@4.5.1/dist/chart.umd.min.js"]
    assets = {}
    def vendor(url):
        target = OUT / "vendor" / url.rsplit("/", 1)[1]
        if not target.exists():
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(urlopen(url, timeout=30).read())
        return url, target
    with ThreadPoolExecutor(max_workers=4) as pool:
        assets.update(pool.map(vendor, urls))
    # Local copies of unmodified imagery for Flutter widget screenshots, too.
    tasks = set()
    for lat, lon in [(10.78,106.70), (10.85,106.76), (10.72,106.65)]:
        for z in [10,11,12,13]:
            n=2**z; x=int((lon+180)/360*n); y=int((1-math.asinh(math.tan(math.radians(lat)))/math.pi)/2*n)
            tasks.update((z,x+dx,y+dy) for dx in range(-3,4) for dy in range(-3,4))
    def tile(t):
        z,x,y=t
        target=ROOT / "build/map-review/tiles" / str(z) / str(x) / f"{y}.jpg"
        if not target.exists():
            data=urlopen(f"https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}",timeout=30).read()
            target.parent.mkdir(parents=True,exist_ok=True); target.write_bytes(data)
    with ThreadPoolExecutor(max_workers=8) as pool:
        list(pool.map(tile, sorted(tasks)))
    return assets


def main():
    from playwright.sync_api import sync_playwright
    logging.getLogger("werkzeug").setLevel(logging.ERROR)
    assets=prepare_assets()
    server=make_server("127.0.0.1",0,app,threaded=True)
    threading.Thread(target=server.serve_forever,daemon=True).start()
    report={"fixture_data_only":True,"checks":[],"screenshots":[]}
    try:
        with sync_playwright() as pw:
            browser=pw.chromium.launch(executable_path=r"C:\Program Files\Google\Chrome\Application\chrome.exe",headless=True)
            context=browser.new_context(device_scale_factor=1,accept_downloads=True)
            def route_resource(route):
                url=route.request.url
                if url in assets:
                    path=assets[url]; route.fulfill(path=str(path),content_type="text/css" if path.suffix==".css" else "application/javascript")
                elif "/World_Imagery/MapServer/tile/" in url:
                    z,y,x=url.split("/tile/")[1].split("?")[0].split("/")
                    path=ROOT/"build/map-review/tiles"/z/x/f"{y}.jpg"
                    if not path.exists():
                        path.parent.mkdir(parents=True,exist_ok=True)
                        path.write_bytes(urlopen(url,timeout=30).read())
                    route.fulfill(path=str(path),content_type="image/jpeg")
                else: route.continue_()
            context.route("https://**/*",route_resource)
            page=context.new_page()
            errors=[]; page.on("pageerror",lambda error:errors.append(str(error)))
            page.set_viewport_size(dict(width=1440,height=1000))
            page.goto(f"http://127.0.0.1:{server.server_port}",wait_until="networkidle")
            page.locator(".station-item").first.wait_for()
            assert page.locator(".station-item").count()==4
            for width,height,kind in [(1440,1000,"desktop"),(390,844,"mobile")]:
                page.set_viewport_size(dict(width=width,height=height))
                page.reload(wait_until="networkidle")
                page.evaluate("window.scrollTo(0,0)")
                page.wait_for_timeout(600)
                # Leaflet keeps offscreen transformed panes; verify the body and
                # unclipped content, rather than those virtual map bounds.
                assert page.evaluate("document.body.scrollWidth <= innerWidth"), f"Body overflow at {width}px"
                assert page.evaluate("Array.from(document.querySelectorAll('body *')).filter(e=>{if(e.getBoundingClientRect().right<=innerWidth+1)return false;for(let p=e.parentElement;p&&p!==document.body;p=p.parentElement){if(getComputedStyle(p).overflowX!=='visible')return false}return true}).length===0"), f"Unclipped content at {width}px"
                page.screenshot(path=str(OUT/f"web-{kind}-main.png"))
                report["screenshots"].append(f"web-{kind}-main.png")
                page.locator("#station-search").fill("Thủ Đức")
                assert page.locator(".station-item").count()==1
                page.locator(".station-item").click()
                page.locator(".leaflet-popup .popup-title").wait_for()
                button_box=page.locator(".popup-button").bounding_box()
                assert button_box["x"] >= 0 and button_box["x"]+button_box["width"] <= width
                assert page.locator(".popup-stats").inner_text().find("Độ ẩm")>=0
                page.wait_for_timeout(900)
                popup_button=page.locator(".popup-button").bounding_box()
                popup_title=page.locator(".popup-title").bounding_box()
                map_box=page.locator("#station-map").bounding_box()
                assert popup_title["y"] >= map_box["y"], "Popup title clipped by map"
                assert popup_button["y"]+popup_button["height"] <= map_box["y"]+map_box["height"], "Popup action clipped by map"
                page.screenshot(path=str(OUT/f"web-{kind}-quick-view.png"))
                report["screenshots"].append(f"web-{kind}-quick-view.png")
                page.locator(".popup-button").click()
                page.locator("#station-detail").scroll_into_view_if_needed()
                page.wait_for_timeout(700)
                assert page.locator("#detail-station-name").inner_text()=="Công viên Thủ Đức"
                page.screenshot(path=str(OUT/f"web-{kind}-detail.png"))
                report["screenshots"].append(f"web-{kind}-detail.png")
                page.locator("#station-search").fill("")
                report["checks"].append(f"{kind}: no horizontal overflow, search, station popup, detail navigation")
            page.set_viewport_size(dict(width=1440,height=1000))
            page.locator("#device-select").select_option("UI_TEST_D")
            page.wait_for_function("document.getElementById('forecast-message').textContent.includes('12 giờ dữ liệu liên tiếp')")
            report["checks"].append("forecast preserves insufficient_data reason from API")
            page.locator("#device-select").select_option("UI_TEST_A")
            page.wait_for_function("document.getElementById('export-history').disabled === false")
            with page.expect_download() as download:
                page.locator("#export-history").click()
            target=OUT/"history-test.csv"; download.value.save_as(str(target))
            assert "Chỉ số nóng bức" in target.read_text(encoding="utf-8-sig")
            report["checks"].append("history CSV download contains Vietnamese headers")
            page.locator("#history-filter button[type=submit]").click()
            page.wait_for_timeout(500)
            page.locator("#add-device").click()
            page.locator("#form-device-id").fill("UI_TEST_NEW")
            page.locator("#form-device-name").fill("Trạm kiểm tra giao diện")
            page.locator("#form-latitude").fill("10.77")
            page.locator("#form-longitude").fill("106.7")
            page.locator("#save-device").click()
            page.wait_for_function("!document.getElementById('device-dialog').open")
            page.wait_for_timeout(400)
            assert page.locator("#device-rows").inner_text().find("Trạm kiểm tra giao diện")>=0
            row=page.locator("#device-rows tr").filter(has_text="UI_TEST_NEW")
            row.get_by_role("button",name="Sửa",exact=False).click()
            page.locator("#form-device-name").fill("Trạm đã đổi tên")
            page.locator("#save-device").click()
            page.wait_for_function("!document.getElementById('device-dialog').open")
            page.wait_for_timeout(300)
            assert "Trạm đã đổi tên" in row.inner_text()
            page.once("dialog",lambda dialog:dialog.accept())
            row.get_by_role("button",name="Tạm ngưng",exact=False).click()
            page.wait_for_function("document.getElementById('device-rows').textContent.includes('Đã tắt')")
            row.get_by_role("button",name="Sửa",exact=False).click()
            page.locator("#form-enabled").check()
            page.locator("#save-device").click()
            page.wait_for_function("!document.getElementById('device-dialog').open")
            page.locator("#device-select").select_option("UI_TEST_A")
            report["checks"].append("history filter, create, rename, pause and resume device work on isolated API")
            before=devices[0]["latest"]["heat_index"]
            devices[0]["latest"]["heat_index"]=36.2
            page.wait_for_function("document.getElementById('heat-index').textContent==='36.2'",timeout=25000)
            report["checks"].append(f"15s polling refreshes heat index from {before} to 36.2 without reload")
            assert not errors, errors
            report["passed"]=True
            context.close(); browser.close()
    finally:
        server.shutdown();server.server_close()
        (OUT/"web-result.json").write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding="utf-8")
        print(json.dumps(report,ensure_ascii=False,indent=2))


if __name__=="__main__":
    if "--serve" in sys.argv:
        print("ISOLATED UI FIXTURE API: http://127.0.0.1:5056 (no MySQL/MQTT)", flush=True)
        app.run(host="127.0.0.1",port=5056,debug=False,use_reloader=False)
    else:
        main()
