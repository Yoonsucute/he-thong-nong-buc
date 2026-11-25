"""Privacy/geolocation UI checks. Browser positions are simulated, never real GPS.

No simulated location is sent to the project server or routing providers:
route requests in these tests are intercepted inside the browser.
"""
import json
from pathlib import Path
import sys
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/ui-test-deps"))
from playwright.sync_api import expect, sync_playwright


def main():
    base = "http://127.0.0.1:5000"
    out = ROOT / "build/user-location-review"
    out.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "simulated_geolocation_only": True, "checks": [], "screenshots": []}
    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=r"C:\Program Files\Google\Chrome\Application\chrome.exe", headless=True)
        errors = []
        def context(**kwargs):
            ctx = browser.new_context(reduced_motion="reduce", viewport={"width": 1440, "height": 1000}, **kwargs)
            def vendor(route):
                path = ROOT / "build/ui-review/vendor" / route.request.url.rsplit("/", 1)[-1]
                if path.is_file() and path.suffix in (".js", ".css"):
                    route.fulfill(path=str(path), content_type="text/css" if path.suffix == ".css" else "application/javascript")
                else:
                    route.continue_()
            ctx.route("https://unpkg.com/**", vendor)
            ctx.route("https://cdn.jsdelivr.net/**", vendor)
            return ctx
        def new_page(ctx):
            tab = ctx.new_page()
            tab.on("pageerror", lambda error: errors.append(str(error)))
            tab.goto(base, wait_until="networkidle")
            expect(tab.locator("#locate-me")).to_be_attached()
            return tab
        try:
            # Real browser API, using Playwright's supplied position and permission.
            ctx = context(geolocation={"latitude": 10.763219, "longitude": 106.682431, "accuracy": 65}, permissions=["geolocation"])
            ctx.add_init_script("""window.__geoCalls = 0;
              const original = navigator.geolocation.getCurrentPosition.bind(navigator.geolocation);
              navigator.geolocation.getCurrentPosition = (...args) => { window.__geoCalls++; return original(...args); };""")
            page = ctx.new_page()
            traffic = []
            page.on("request", lambda req: traffic.append(req.url))
            page.on("pageerror", lambda error: errors.append(str(error)))
            page.goto(base, wait_until="networkidle")
            expect(page.locator("#enable-user-location")).to_be_visible()
            expect(page.locator("#defer-user-location")).to_be_visible()
            assert page.evaluate("window.__geoCalls") == 0
            assert not any("/api/rain-route" in url for url in traffic)
            page.screenshot(path=str(out / "first-visit-desktop.png"))
            report["screenshots"].append("first-visit-desktop.png")
            report["checks"].append("first visit: both choices visible; no automatic geolocation or route/geocoder request")
            page.evaluate("""() => {
              const circle = L.circle, fit = L.Map.prototype.fitBounds;
              L.circle = (point, options) => { window.__accuracyRadius = options.radius; return circle(point, options); };
              L.Map.prototype.fitBounds = function(bounds, options) { window.__fitCenter = L.latLngBounds(bounds).getCenter(); return fit.call(this, bounds, options); };
            }""")
            station_count = page.locator(".station-pin").count()
            page.locator("#enable-user-location").click()
            expect(page.locator("path.user-location-dot")).to_have_count(1)
            expect(page.locator("path.user-location-accuracy")).to_have_count(1)
            expect(page.locator(".user-location-tooltip")).to_have_text("Vị trí của bạn")
            expect(page.locator("#location-invitation")).not_to_be_visible()
            assert page.evaluate("window.__accuracyRadius") == 65
            center = page.evaluate("window.__fitCenter")
            assert abs(center["lat"] - 10.763219) < .0001
            assert abs(center["lng"] - 106.682431) < .0001
            assert page.evaluate("window.__geoCalls") == 1
            expect(page.locator("#route-start")).to_have_value("Vị trí của tôi")
            assert not any("/api/rain-route" in url or "10.763219" in url or "106.682431" in url for url in traffic)
            assert page.evaluate("localStorage.length === 0 && sessionStorage.length === 1 && sessionStorage.getItem('heatwatch.location.invited') === '1'")
            page.locator("#station-map").screenshot(path=str(out / "blue-dot-and-accuracy.png"))
            report["screenshots"].append("blue-dot-and-accuracy.png")
            report["checks"].append("opt-in: real browser geolocation uses simulated fix, blue dot/label/65m circle, centered map, no coordinate upload or persistence")
            page.locator("#use-my-location-start").click()
            expect(page.locator("#route-start")).to_have_value("Vị trí của tôi")
            assert not any("/api/rain-route" in url for url in traffic)
            page.locator("#search-route-start").click()
            assert not any("/api/rain-route/geocode" in url for url in traffic)
            submissions = []
            ctx.route("**/api/rain-route?*", lambda route: (submissions.append(parse_qs(urlparse(route.request.url).query)), route.fulfill(status=503, json={"error": "Kết thúc kiểm tra riêng tư; không gửi tọa độ mô phỏng tới máy chủ."})))
            page.locator("#route-end").fill("10.8015,106.6526")
            page.locator("#find-rain-route").click()
            expect(page.locator("#rain-route-status")).to_contain_text("Kết thúc kiểm tra")
            assert len(submissions) == 1
            assert submissions[0]["start"] == ["10.763219,106.682431"]
            report["checks"].append("location origin stays local even on address-search click; coordinates appear only in explicit Find request, intercepted before server")
            page.locator("#route-start").fill("10.7711,106.69")
            page.locator("#find-rain-route").click()
            page.wait_for_function("document.getElementById('find-rain-route').disabled === false")
            assert len(submissions) == 2 and submissions[1]["start"] == ["10.7711,106.69"]
            ctx.set_geolocation({"latitude": 10.764321, "longitude": 106.683219, "accuracy": 25})
            page.locator("#locate-me").click()
            expect(page.locator("#user-location-status")).to_contain_text("25 m")
            assert page.evaluate("window.__geoCalls") == 2
            assert page.locator("#route-start").input_value() == "10.7711,106.69"
            assert page.locator("path.user-location-dot").count() == 1
            assert page.locator("path.user-location-accuracy").count() == 1
            assert page.locator(".station-pin").count() == station_count
            assert len(submissions) == 2
            page.set_viewport_size({"width": 390, "height": 844})
            assert page.evaluate("document.body.scrollWidth <= innerWidth")
            page.locator("#station-map").screenshot(path=str(out / "mobile-location-map.png"))
            report["screenshots"].append("mobile-location-map.png")
            report["checks"].append("origin remains editable; locate-again updates one marker/circle without overriding manual origin or uploading; station pins remain")
            page.reload(wait_until="networkidle")
            assert page.evaluate("window.HeatWatchLocation.getPosition()") is None
            assert page.evaluate("window.__geoCalls") == 0
            assert page.locator("path.user-location-dot").count() == 0
            expect(page.locator("#location-invitation")).not_to_be_visible()
            assert page.evaluate("window.__geoCalls") == 0
            assert page.locator("#route-start").is_editable()
            assert page.locator("#station-search").is_editable()
            report["checks"].append("reload drops coordinates; Defer never asks browser permission and keeps public map/manual origin usable")
            # Explicit API failures are simulated to cover device/permission cases.
            for code, phrase in ((1, "chưa cho phép"), (2, "chưa xác định"), (3, "quá lâu")):
                failure = context()
                failure.add_init_script(f"""window.__geoCalls = 0;
                  Object.defineProperty(navigator, 'geolocation', {{value: {{getCurrentPosition(ok, fail) {{window.__geoCalls++; queueMicrotask(() => fail({{code:{code}}}));}}}}}});""")
                tab = new_page(failure)
                tab.locator("#enable-user-location").click()
                expect(tab.locator("#location-invite-message")).to_contain_text(phrase)
                assert tab.locator("path.user-location-dot").count() == 0
                assert tab.locator("#route-start").is_editable()
                tab.locator("#defer-user-location").click()
                tab.locator("#locate-me").click()
                assert tab.evaluate("window.__geoCalls") == 2
                failure.close()
            report["checks"].append("simulated permission denied, position unavailable and timeout: explanatory messages, retry button and manual origin remain usable")
            # Late callbacks must neither override a manually edited origin nor
            # restore a position after the user explicitly picked Defer.
            delayed = context()
            delayed.add_init_script("""Object.defineProperty(navigator, 'geolocation', {value: {getCurrentPosition(ok) { window.__finishGeo = () => ok({coords:{latitude:10.76, longitude:106.68, accuracy:40},timestamp:Date.now()}); }}});""")
            tab = new_page(delayed)
            tab.locator("#defer-user-location").click()
            tab.locator("#use-my-location-start").click()
            tab.locator("#route-start").fill("10.78,106.7")
            tab.evaluate("window.__finishGeo()")
            expect(tab.locator("#route-start")).to_have_value("10.78,106.7")
            tab.evaluate("sessionStorage.clear()")
            tab.reload(wait_until="networkidle")
            tab.locator("#enable-user-location").click()
            tab.locator("#defer-user-location").click()
            tab.evaluate("window.__finishGeo()")
            assert tab.evaluate("window.HeatWatchLocation.getPosition()") is None
            assert tab.locator("path.user-location-dot").count() == 0
            report["checks"].append("late callback does not overwrite manual origin or undo Defer")
            # Hold the first real station request to cover geolocation winning
            # the race against the dashboard's initial auto-fit.
            held_context = context(geolocation={"latitude": 10.763219, "longitude": 106.682431, "accuracy": 65}, permissions=["geolocation"])
            held_requests = []
            def hold_first(route):
                if not held_requests:
                    held_requests.append(route)
                else:
                    route.continue_()
            held_context.route("**/api/devices", hold_first)
            held_page = held_context.new_page()
            held_page.on("pageerror", lambda error: errors.append(str(error)))
            held_page.goto(base, wait_until="domcontentloaded")
            expect(held_page.locator("#locate-me")).to_be_attached()
            held_page.evaluate("""() => { window.__fitCount = 0; const original = L.Map.prototype.fitBounds;
              L.Map.prototype.fitBounds = function(...args) { window.__fitCount++; return original.apply(this,args); }; }""")
            held_page.locator("#enable-user-location").click()
            expect(held_page.locator("path.user-location-dot")).to_have_count(1)
            assert held_page.evaluate("window.__fitCount") == 1
            assert held_requests
            held_requests[0].continue_()
            expect(held_page.locator(".station-pin").first).to_be_attached()
            assert held_page.evaluate("window.__fitCount") == 1
            report["checks"].append("late first station response preserves the geolocation-centered viewport")
            unsupported = context()
            unsupported.add_init_script("Object.defineProperty(navigator, 'geolocation', {value: undefined});")
            tab = new_page(unsupported)
            tab.locator("#enable-user-location").click()
            expect(tab.locator("#location-invite-message")).to_contain_text("chưa hỗ trợ")
            assert tab.locator("#route-start").is_editable()
            report["checks"].append("unsupported geolocation falls back to manual origin")
            assert not errors, errors
            report["passed"] = True
        finally:
            (out / "result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps(report, ensure_ascii=True, indent=2))
            browser.close()


if __name__ == "__main__":
    main()
