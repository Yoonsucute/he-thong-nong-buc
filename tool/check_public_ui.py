"""Chrome checks for the public weather view against running Flask/MySQL.

Optional HEATWATCH_ADMIN_PASSWORD enables the admin login/form regression check.
No API responses or sensor data are substituted. No station data is changed.
"""
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/ui-test-deps"))
from playwright.sync_api import expect, sync_playwright


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:5000")
    parser.add_argument("--username", default="admin")
    args = parser.parse_args()
    base = args.url.rstrip("/")
    out = ROOT / "build/public-ui-review"
    out.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "real_api": True, "fixture_data": False, "checks": [], "screenshots": []}
    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=r"C:\Program Files\Google\Chrome\Application\chrome.exe", headless=True)
        context = browser.new_context(reduced_motion="reduce", accept_downloads=True)
        # Unmodified CDN assets may come from the existing local cache.
        def vendor(route):
            path = ROOT / "build/ui-review/vendor" / route.request.url.split("?")[0].rsplit("/", 1)[-1]
            if path.is_file() and path.suffix in (".js", ".css"):
                route.fulfill(path=str(path), content_type="text/css" if path.suffix == ".css" else "application/javascript")
            else:
                route.continue_()
        context.route("https://unpkg.com/**", vendor)
        context.route("https://cdn.jsdelivr.net/**", vendor)
        page = context.new_page()
        errors = []
        page.on("pageerror", lambda error: errors.append(str(error)))
        try:
            for width, height, label in ((1440, 1000, "desktop"), (1024, 900, "small-desktop"), (768, 1024, "tablet"), (390, 844, "mobile"), (360, 800, "small-mobile")):
                page.set_viewport_size({"width": width, "height": height})
                with page.expect_response(lambda r: r.url == base + "/api/devices" and r.request.method == "GET") as loaded:
                    response = page.goto(base + "/", wait_until="networkidle")
                assert response.status == 200
                stations = loaded.value.json()
                active = [d for d in stations if d["enabled"]]
                assert active, "Real API needs at least one enabled station for these checks"
                selected = active[0]
                expect(page.locator("#detail-station-name")).to_have_text(selected["name"])
                for field, key in (("#heat-index", "heat_index"), ("#temperature", "temperature"), ("#humidity", "humidity")):
                    value = (selected.get("latest") or {}).get(key)
                    expect(page.locator(field)).to_have_text("—" if value is None else f"{value:.1f}")
                assert page.locator(".sidebar, .topbar, #devices, #device-dialog, #admin-csrf, table").count() == 0
                assert page.locator('.public-header a.nav-item').all_text_contents()[:2] == ["Bản đồ", "Điểm đo"]
                for scope in (page.locator(".public-header"), page.locator("footer")):
                    assert not any(word in scope.inner_text().lower() for word in ("đăng nhập", "đăng ký", "quản trị", "đăng xuất"))
                    assert scope.locator('a[href*="admin"], a[href*="login"], a[href*="register"]').count() == 0
                assert page.evaluate("document.body.scrollWidth <= innerWidth"), f"Horizontal overflow at {width}px"
                current = page.locator("#public-current").bounding_box()
                chart = page.locator("#overview").bounding_box()
                assert current["y"] < chart["y"]
                heat = page.locator("#heat-index").bounding_box()
                assert heat["y"] + heat["height"] < height, "Heat index must be visible without scrolling"
                map_box = page.locator(".map-panel").bounding_box()
                list_box = page.locator(".stations-panel").bounding_box()
                if width > 800:
                    assert map_box["x"] + map_box["width"] <= list_box["x"]
                    assert map_box["width"] > list_box["width"]
                else:
                    assert map_box["y"] + map_box["height"] <= list_box["y"]
                page.screenshot(path=str(out / f"{label}-top.png"))
                report["screenshots"].append(f"{label}-top.png")
                page.locator("#station-search").fill(selected["device_id"])
                expect(page.locator(".station-item")).to_have_count(1)
                page.locator("#station-search").fill("NO_SUCH_STATION_7419")
                expect(page.locator(".station-item")).to_have_count(0)
                expect(page.locator("#station-list")).to_contain_text("Không tìm thấy trạm")
                page.locator("#station-search").fill("")
                expect(page.locator(".station-item")).to_have_count(len(active))
                card = page.locator(".station-item").filter(has_text=selected["device_id"]).first
                with page.expect_response(lambda r: "/api/sensor/history?" in r.url):
                    card.click()
                expect(page.locator("#detail-station-name")).to_have_text(selected["name"])
                # Change only the displayed label, then prove marker selection renders
                # the real station again. This does not alter API or sensor data.
                marker = page.locator(".leaflet-marker-icon").filter(has=page.locator(".station-pin")).first
                if marker.count():
                    page.locator("#detail-station-name").evaluate("e => e.textContent = 'Selection pending'")
                    marker.click()
                    expect(page.locator("#detail-station-name")).not_to_have_text("Selection pending")
                    expect(page.locator(".leaflet-popup .popup-title")).to_be_visible()
                    with page.expect_response(lambda r: "/api/sensor/history?" in r.url):
                        page.locator(".popup-button").click()
                    assert page.locator("#station-detail").evaluate("e => e.open")
                    expect(page.locator("#history-title")).to_be_visible()
                    expect(page.locator(".history-reading").first).to_be_visible()
                page.locator('.public-header a[href="#alerts"]').click()
                expect(page.locator("#alerts-title")).to_be_in_viewport()
                expect(page.locator("#alert-message")).not_to_have_text("Đang tải cảnh báo…")
                page.locator("#alerts").screenshot(path=str(out / f"{label}-alerts.png"))
                report["screenshots"].append(f"{label}-alerts.png")
                page.locator("#station-detail").evaluate("e => e.open = false")
                page.evaluate("window.scrollTo(0,0)")
                page.screenshot(path=str(out / f"{label}-full.png"), full_page=True)
                report["screenshots"].append(f"{label}-full.png")
                report["checks"].append(f"{width}x{height}: real readings, public navigation, responsive map/list, search, station/marker selection, details, alerts")
            # Authentication regression uses a separate fresh session.
            owner_context = browser.new_context(viewport={"width": 1440, "height": 1000})
            owner_context.route("https://unpkg.com/**", vendor)
            owner_context.route("https://cdn.jsdelivr.net/**", vendor)
            owner = owner_context.new_page()
            owner.on("pageerror", lambda error: errors.append(str(error)))
            owner.goto(base + "/admin", wait_until="domcontentloaded")
            expect(owner).to_have_url(base + "/admin/login")
            report["checks"].append("anonymous /admin still redirects to login")
            password = os.getenv("HEATWATCH_ADMIN_PASSWORD")
            if password:
                owner.locator("#username").fill(args.username)
                owner.locator("#password").fill(password)
                owner.get_by_role("button", name="Đăng nhập", exact=True).click()
                expect(owner).to_have_url(base + "/admin")
                expect(owner.locator(".sidebar")).to_be_visible()
                expect(owner.locator("#device-rows tr").first).to_be_visible()
                assert owner.locator('link[href*="public.css"]').count() == 0
                assert owner.locator(".public-header").count() == 0
                row = owner.locator("#device-rows tr").first
                row.get_by_role("button", name="Sửa", exact=False).click()
                expect(owner.locator("#device-dialog")).to_be_visible()
                assert owner.locator("#form-device-id").input_value()
                assert owner.locator("#form-device-name").input_value()
                assert owner.locator("#save-device").is_enabled()
                owner.locator("#cancel-dialog").click()
                owner.screenshot(path=str(out / "admin-unchanged.png"), full_page=True)
                report["screenshots"].append("admin-unchanged.png")
                owner.get_by_role("button", name="Đăng xuất", exact=True).click()
                expect(owner).to_have_url(base + "/")
                expect(owner.locator(".public-header")).to_be_visible()
                report["checks"].append("real admin login, original sidebar/table, populated station editor, cancel and logout unchanged")
            else:
                report["admin_login_skipped"] = "Set HEATWATCH_ADMIN_PASSWORD to verify admin login and editor"
            assert not errors, errors
            report["passed"] = True
        finally:
            (out / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps(report, ensure_ascii=True, indent=2))
            browser.close()


if __name__ == "__main__":
    main()
