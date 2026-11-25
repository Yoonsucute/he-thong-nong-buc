"""Browser checks with real Valhalla/Open-Meteo; explicit fixtures test overlays.

Run against Flask on :5000. External data is never persisted to project DB.
Fixtures are confined to a second browser context and labelled in the report.
"""
import copy
from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "build/ui-test-deps"))
from playwright.sync_api import expect, sync_playwright


def main():
    base = "http://127.0.0.1:5000"
    out = ROOT / "build/route-heat-review"
    out.mkdir(parents=True, exist_ok=True)
    report = {"passed": False, "live_checks": [], "fixture_checks": [], "screenshots": []}
    with sync_playwright() as pw:
        browser = pw.chromium.launch(executable_path=r"C:\Program Files\Google\Chrome\Application\chrome.exe", headless=True)
        context = browser.new_context(viewport={"width": 1440, "height": 1100}, reduced_motion="reduce")
        def vendor(route):
            path = ROOT / "build/ui-review/vendor" / route.request.url.rsplit("/", 1)[-1]
            if path.is_file() and path.suffix in (".js", ".css"):
                route.fulfill(path=str(path), content_type="text/css" if path.suffix == ".css" else "application/javascript")
            else:
                route.continue_()
        context.route("https://unpkg.com/**", vendor)
        context.route("https://cdn.jsdelivr.net/**", vendor)
        errors = []
        page = context.new_page()
        page.on("pageerror", lambda error: errors.append(str(error)))
        def inputs(tab):
            tab.locator("#route-start").fill("10.7721,106.6983")
            tab.locator("#route-end").fill("10.8015,106.6526")
        def submit(tab):
            with tab.expect_response(lambda r: "/api/rain-route?" in r.url, timeout=85000) as saved:
                tab.locator("#find-rain-route").click()
            assert saved.value.status == 200, saved.value.text()
            data = saved.value.json()
            expect(tab.locator("#rain-route-results")).to_be_visible(timeout=10000)
            assert tab.locator(".route-cards > .route-card").count() == 3
            assert tab.locator(".leaflet-rainRouteLines-pane path").count() >= 2
            expect(tab.locator(".leaflet-rainRouteLines-pane svg")).to_be_visible()
            svg_box = tab.locator(".leaflet-rainRouteLines-pane svg").bounding_box()
            assert svg_box["width"] > 100 and svg_box["height"] > 100, "Map SVG must not inherit small UI-icon dimensions"
            return data
        try:
            page.goto(base, wait_until="networkidle")
            if page.locator("#defer-user-location").is_visible():
                page.locator("#defer-user-location").click()
            expect(page.locator(".station-pin").first).to_be_attached()
            station_count = page.locator(".station-pin").count()
            page.locator("#route-start").fill("Ben Thanh, Ho Chi Minh")
            page.locator("#search-route-start").click()
            expect(page.locator("#route-start-results .place-choice").first).to_be_visible(timeout=20000)
            page.locator("#route-start-results .place-choice").first.click()
            assert page.locator("#route-start-selection").get_attribute("class").find("chosen") >= 0
            report["live_checks"].append("explicit OSM address lookup and location selection work without login")
            inputs(page)
            data = submit(page)
            assert data["vehicle"] == "motorcycle"
            assert data["recommended_route_id"]
            assert data["lowest_risk_route_id"]
            assert all(route["weather_complete"] and route["heat_complete"] for route in data["routes"])
            expect(page.locator(".route-card.recommended")).to_contain_text("Cân bằng điểm rủi ro")
            expect(page.locator(".route-card.lowest_risk")).to_contain_text("Xác suất mưa")
            page.locator(".route-card.shortest").click()
            expect(page.locator(".route-card.shortest")).to_have_attribute("aria-pressed", "true")
            expect(page.locator(".route-card[aria-pressed='true']")).to_have_count(1)
            featured = {data["recommended_route_id"], data["shortest_route_id"], data["lowest_risk_route_id"]}
            if any(route["id"] not in featured for route in data["routes"]):
                page.locator(".route-other-choices summary").click()
                expect(page.locator(".route-other-list .route-card").first).to_be_visible()
                page.locator(".route-other-list .route-card").first.click()
                expect(page.locator(".route-other-list .route-card[aria-pressed='true']")).to_have_count(1)
                page.locator(".route-other-choices summary").click()
            assert "km" in page.locator("#rain-route-cards").inner_text()
            assert page.locator(".station-pin").count() == station_count
            page.locator("#rain-planner").screenshot(path=str(out / "desktop-live.png"))
            report["screenshots"].append("desktop-live.png")
            report["live_checks"].append(f"motorcycle/now: {len(data['routes'])} real routes, km/ETA, heat and rain coverage, three comparison cards and route selection")
            # Changing vehicle clears stale results; scheduled time is interpreted
            # explicitly in Vietnam time, independently of the browser timezone.
            page.locator("#route-vehicle").select_option("car")
            expect(page.locator("#rain-route-results")).not_to_be_visible()
            page.locator("#route-departure-mode").select_option("scheduled")
            departure = datetime.now(timezone(timedelta(hours=7))) + timedelta(hours=1)
            page.locator("#route-departure").fill(departure.strftime("%Y-%m-%dT%H:%M"))
            scheduled = submit(page)
            assert scheduled["vehicle"] == "car"
            assert datetime.fromisoformat(scheduled["departure_at"]).astimezone(timezone(timedelta(hours=7))).strftime("%H:%M") == departure.strftime("%H:%M")
            assert page.locator(".station-pin").count() == station_count
            report["live_checks"].append("car/scheduled: real timed route search; changing options clears stale overlays")
            count = page.locator(".leaflet-rainRouteLines-pane path").count()
            # Exercise the existing 15s polling without relying on a sleep.
            previous = page.locator("#sync-time").inner_text()
            page.wait_for_function("before => document.getElementById('sync-time').textContent !== before", arg=previous, timeout=22000)
            assert page.locator(".leaflet-rainRouteLines-pane path").count() == count
            assert page.locator(".station-pin").count() == station_count
            report["live_checks"].append("station polling preserves route overlays and station pins")
            page.set_viewport_size({"width": 390, "height": 844})
            assert page.evaluate("document.body.scrollWidth <= innerWidth")
            page.locator("#rain-planner").screenshot(path=str(out / "mobile-live.png"))
            report["screenshots"].append("mobile-live.png")
            page.locator("#clear-rain-route").click()
            assert page.locator(".leaflet-rainRouteLines-pane path").count() == 0
            assert page.locator(".station-pin").count() == station_count
            page.locator("#pick-route-start").click()
            page.locator("#station-map").click(position={"x": 100, "y": 140})
            expect(page.locator("#route-start-selection")).to_have_class("place-selection chosen")
            assert page.locator(".route-endpoint.start").count() == 1
            page.locator("#open-station-detail").click()
            expect(page.locator("#forecast-message")).to_be_visible()
            assert page.locator("#forecast-message").inner_text()
            assert page.locator("#temperature").inner_text() != "—"
            assert page.locator("a[href='/admin'], a[href='/admin/login']").count() == 0
            report["live_checks"].append("mobile: no overflow, clear/map-pick work, pins remain, LSTM forecast section and current heat readings remain public")
            # Separate context, explicit deterministic weather fixtures: exercise
            # rain colours and missing data even if the real forecast is dry.
            fixture_context = browser.new_context(viewport={"width": 1440, "height": 1000}, reduced_motion="reduce")
            fixture_context.route("https://unpkg.com/**", vendor)
            fixture_context.route("https://cdn.jsdelivr.net/**", vendor)
            fixture = fixture_context.new_page()
            fixture.on("pageerror", lambda error: errors.append(str(error)))
            fixture_data = copy.deepcopy(data)
            for route in fixture_data["routes"]:
                for index, segment in enumerate(route["segments"]):
                    segment.update(risk="high" if index % 2 else "moderate", probability_percent=85 if index % 2 else 45,
                                   precipitation_mm=3 if index % 2 else .5, heat_source="esp32" if index % 2 else "open_meteo")
            fixture_context.route("**/api/rain-route?*", lambda route: route.fulfill(json=fixture_data))
            fixture.goto(base, wait_until="networkidle")
            if fixture.locator("#defer-user-location").is_visible():
                fixture.locator("#defer-user-location").click()
            inputs(fixture)
            submit(fixture)
            expect(fixture.locator("path.rain-segment.high").first).to_be_attached()
            expect(fixture.locator("path.rain-segment.moderate").first).to_be_attached()
            expect(fixture.locator("path.rain-segment.moderate").first).to_have_attribute("stroke-dasharray", "9 6")
            fixture.locator("#station-map").scroll_into_view_if_needed()
            fixture.wait_for_timeout(500)
            fixture.screenshot(path=str(out / "heat-risk-overlays-fixture.png"))
            report["screenshots"].append("heat-risk-overlays-fixture.png")
            report["fixture_checks"].append("explicit fixture: warning and high-risk segments plus source-specific line styles")
            fixture_data["recommended_route_id"] = None
            fixture_data["lowest_risk_route_id"] = None
            fixture_data["warnings"] = ["Dự báo mưa bị thiếu (fixture kiểm thử)"]
            for route in fixture_data["routes"]:
                route.update(weather_complete=False, weather_coverage_percent=0, expected_rain_minutes=None, rain_score=None)
                for segment in route["segments"]:
                    segment.update(risk="unknown", probability_percent=None, precipitation_mm=None)
            fixture.locator("#clear-rain-route").click()
            submit(fixture)
            expect(fixture.locator(".route-card.unavailable")).to_have_count(2)
            expect(fixture.locator(".route-card.recommended")).to_contain_text("Chưa đủ dữ liệu")
            assert fixture.locator("path.rain-segment.unknown").count() > 0
            report["fixture_checks"].append("explicit fixture: missing weather produces unknown segments, no dry recommendation")
            assert not errors, errors
            report["passed"] = True
        finally:
            (out / "browser-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            print(json.dumps(report, ensure_ascii=True, indent=2))
            browser.close()


if __name__ == "__main__":
    main()
