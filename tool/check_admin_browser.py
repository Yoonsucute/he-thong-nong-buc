"""Exercise the running Flask app and real database in fresh Chrome contexts.

Run from the project root: python tool/check_admin_browser.py
Requires Playwright and Chrome. Temporarily renames one existing station and
restores its name in finally. Never substitutes API responses or sensor data.
"""
import argparse
import json
import os
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/ui-test-deps"))
from playwright.sync_api import sync_playwright, expect


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:5000")
    parser.add_argument("--credentials", type=Path, default=ROOT / "backend/instance/ADMIN_CREDENTIALS.txt")
    args = parser.parse_args()
    if os.environ.get("HEATWATCH_TEST_ADMIN_PASSWORD"):
        credentials = {"Username": os.environ.get("HEATWATCH_TEST_ADMIN_USER", "admin"), "Password": os.environ["HEATWATCH_TEST_ADMIN_PASSWORD"]}
    else:
        credentials = dict(line.split(": ", 1) for line in args.credentials.read_text(encoding="utf-8").splitlines() if ": " in line)
    out = ROOT / "build/admin-browser-review"
    out.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "real_flask_api": True, "fixture_data": False,
              "incognito_contexts": True, "checks": [], "screenshots": []}
    base = args.url.rstrip("/")
    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=r"C:\Program Files\Google\Chrome\Application\chrome.exe", headless=True)
        public = browser.new_context(viewport={"width": 1440, "height": 1000})
        admin = browser.new_context(viewport={"width": 1440, "height": 1000})
        # Cached, unmodified CDN assets only. All local API traffic is real.
        def vendor(route):
            path = ROOT / "build/ui-review/vendor" / route.request.url.split("?")[0].rsplit("/", 1)[-1]
            if path.is_file() and path.suffix in (".js", ".css"):
                route.fulfill(path=str(path), content_type="text/css" if path.suffix == ".css" else "application/javascript")
            else:
                route.continue_()
        for context in (public, admin):
            context.route("https://cdn.jsdelivr.net/**", vendor)
            context.route("https://unpkg.com/**", vendor)
        page, owner = public.new_page(), admin.new_page()
        errors = []
        for tab in (page, owner):
            tab.on("pageerror", lambda error: errors.append(str(error)))
        original = None
        csrf = None
        modified = False
        try:
            assert page.goto(base + "/", wait_until="domcontentloaded").status == 200
            page.locator("#defer-user-location").click()
            expect(page.locator(".station-item").first).to_be_visible(timeout=20000)
            for width, height, label in ((1440, 1000, "desktop"), (390, 844, "mobile")):
                page.set_viewport_size({"width": width, "height": height})
                for scope in (page.locator(".public-header"), page.locator("nav"), page.locator("footer")):
                    assert scope.count() > 0
                    assert not any(text in scope.inner_text().lower() for text in ("đăng nhập", "đăng ký", "quản trị", "đăng xuất"))
                    assert scope.locator('a[href*="admin"], a[href*="login"], a[href*="register"]').count() == 0
                assert page.locator("#device-dialog, #devices, #admin-csrf").count() == 0
                expect(page.locator("#station-map .leaflet-pane").first).to_be_attached()
                assert page.evaluate("document.body.scrollWidth <= innerWidth")
                page.screenshot(path=str(out / f"public-{label}.png"), full_page=True)
                report["screenshots"].append(f"public-{label}.png")
                report["checks"].append(f"public {label}: map, station list, no account/admin links in menu or footer")
            for selector in ("#temperature", "#humidity", "#heat-index", "#alerts"):
                expect(page.locator(selector)).to_be_attached()
            for path in ("/api/devices", "/api/sensor/latest", "/api/sensor/history", "/api/sensor/forecast", "/api/alerts", "/api/health"):
                response = public.request.get(base + path)
                assert response.status not in (401, 403, 500, 503), (path, response.status)
            report["checks"].append("all six existing read APIs available without login")
            stations = public.request.get(base + "/api/devices").json()
            original = next(station for station in stations if station["enabled"])
            device_id = original["device_id"]
            for method, path in (("POST", "/api/devices"), ("PUT", f"/api/devices/{device_id}"), ("DELETE", f"/api/devices/{device_id}")):
                response = public.request.fetch(base + path, method=method, data={"name": "Unauthorized"})
                assert response.status == 401, (method, response.status)
                assert response.json()["code"] == "admin_required"
            report["checks"].append("direct anonymous create/update/delete API calls return 401")
            owner.goto(base + "/admin", wait_until="domcontentloaded")
            expect(owner).to_have_url(base + "/admin/login")
            report["checks"].append("anonymous /admin redirects to /admin/login")
            owner.locator("#username").fill(credentials["Username"])
            owner.locator("#password").fill(credentials["Password"])
            owner.get_by_role("button", name="Đăng nhập", exact=True).click()
            expect(owner).to_have_url(base + "/admin")
            expect(owner.locator("#device-rows tr").filter(has_text=device_id)).to_be_visible()
            csrf = owner.locator("#admin-csrf").get_attribute("content")
            assert admin.request.put(base + f"/api/devices/{device_id}", data={"name": "Missing CSRF"}).status == 403
            report["checks"].append("real admin login succeeds; authenticated write without CSRF returns 403")
            updated = original["name"][:100] + " · Kiểm thử admin"
            row = owner.locator("#device-rows tr").filter(has_text=device_id)
            row.get_by_role("button", name="Sửa", exact=False).click()
            owner.locator("#form-device-name").fill(updated)
            # Set before submission so even a partial failure triggers restoration.
            modified = True
            with owner.expect_response(lambda response: response.request.method == "PUT" and "/api/devices/" in response.url) as saved:
                owner.locator("#save-device").click()
            assert saved.value.status == 200
            expect(owner.locator("#device-dialog")).not_to_be_visible()
            expect(row).to_contain_text(updated)
            # Public page must pick up persisted data through its normal 15s polling.
            expect(page.locator("#station-list")).to_contain_text(updated, timeout=25000)
            current = next(d for d in public.request.get(base + "/api/devices").json() if d["device_id"] == device_id)
            assert current["name"] == updated
            assert (current["latitude"], current["longitude"]) == (original["latitude"], original["longitude"])
            page.screenshot(path=str(out / "public-updated.png"), full_page=True)
            owner.screenshot(path=str(out / "admin-updated.png"), full_page=True)
            report["screenshots"].extend(["public-updated.png", "admin-updated.png"])
            report["checks"].append("station renamed through admin UI; independent public incognito page updates through polling; coordinates preserved")
            restored = admin.request.put(base + f"/api/devices/{device_id}", data={"name": original["name"]}, headers={"X-CSRF-Token": csrf})
            assert restored.status == 200
            assert next(d for d in public.request.get(base + "/api/devices").json() if d["device_id"] == device_id)["name"] == original["name"]
            modified = False
            report["station_name_restored"] = True
            owner.get_by_role("button", name="Đăng xuất", exact=True).click()
            expect(owner).to_have_url(base + "/")
            assert owner.locator("#devices, #admin-csrf").count() == 0
            assert admin.request.put(base + f"/api/devices/{device_id}", data={"name": "After logout"}, headers={"X-CSRF-Token": csrf}).status == 401
            report["checks"].append("logout returns to public view and invalidates subsequent management requests")
            assert not errors, errors
            report["passed"] = True
        finally:
            if modified and original and csrf:
                restored = admin.request.put(base + f"/api/devices/{original['device_id']}", data={"name": original["name"]}, headers={"X-CSRF-Token": csrf})
                report["station_name_restored"] = restored.status == 200
            (out / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps(report, ensure_ascii=True, indent=2))
            browser.close()


if __name__ == "__main__":
    main()
