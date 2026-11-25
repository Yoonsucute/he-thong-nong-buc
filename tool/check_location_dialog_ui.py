"""Review the actual Flask dialog in desktop/mobile Chrome; GPS is simulated.

--keep-open leaves fresh desktop/mobile windows without simulated coordinates.
"""
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'build/ui-test-deps'))
from playwright.sync_api import sync_playwright, expect

BASE = 'http://127.0.0.1:5000/'
OUT = ROOT / 'build/material-location-review'


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    report = {'passed': False, 'simulated_geolocation_only': True, 'checks': []}
    with sync_playwright() as pw:
        browser = pw.chromium.launch(
            executable_path=r'C:\Program Files\Google\Chrome\Application\chrome.exe',
            headless='--keep-open' not in sys.argv)

        def context(width, height, **kwargs):
            ctx = browser.new_context(viewport={'width': width, 'height': height}, reduced_motion='reduce', **kwargs)
            def vendor(route):
                asset = ROOT / 'build/ui-review/vendor' / route.request.url.rsplit('/', 1)[-1]
                if asset.is_file() and asset.suffix in ('.js', '.css'):
                    route.fulfill(path=str(asset), content_type='text/css' if asset.suffix == '.css' else 'application/javascript')
                else:
                    route.continue_()
            ctx.route('https://unpkg.com/**', vendor)
            ctx.route('https://cdn.jsdelivr.net/**', vendor)
            return ctx

        try:
            for width, height, name in [(1440, 1000, 'desktop'), (390, 844, 'phone'), (320, 640, 'small-phone')]:
                ctx = context(width, height, permissions=['geolocation'], geolocation={'latitude': 10.7769, 'longitude': 106.7009, 'accuracy': 30})
                page = ctx.new_page()
                errors, traffic = [], []
                page.on('pageerror', lambda error: errors.append(str(error)))
                page.on('request', lambda request: traffic.append(request.url))
                page.goto(BASE, wait_until='networkidle')
                dialog = page.get_by_role('dialog', name='Bật vị trí hiện tại?')
                expect(dialog).to_be_visible()
                expect(dialog).to_contain_text('Hiển thị vị trí của bạn trên bản đồ và dùng làm điểm đi khi tìm đường.')
                box = dialog.bounding_box()
                assert box['width'] <= 380.1
                assert box['x'] >= 15.9 and box['y'] >= 19.9
                layout_width = page.evaluate('document.documentElement.clientWidth')
                assert abs(box['x'] + box['width'] / 2 - layout_width / 2) < 1, box
                assert abs(box['y'] + box['height'] / 2 - height / 2) < 1
                assert page.evaluate('document.body.scrollWidth <= innerWidth')
                defer = page.get_by_role('button', name='Để sau', exact=True)
                use = page.get_by_role('button', name='Dùng vị trí', exact=True)
                assert defer.bounding_box()['x'] < use.bounding_box()['x']
                assert dialog.evaluate('(el) => getComputedStyle(el).backgroundColor') == 'rgb(41, 42, 47)'
                page.bring_to_front()
                page.keyboard.press('Tab')
                expect(use).to_be_focused()
                page.screenshot(path=str(OUT / f'{name}-dialog.png'))
                assert use.evaluate('(el) => el.matches(":focus-visible") && parseFloat(getComputedStyle(el).outlineWidth) >= 2 && getComputedStyle(el).outlineStyle === "solid"')
                defer.click()
                expect(dialog).not_to_be_visible()
                expect(page.locator('#route-start')).to_be_editable()
                assert page.evaluate('window.HeatWatchLocation.getPosition()') is None
                assert not any('/api/rain-route' in url for url in traffic)
                page.evaluate('sessionStorage.clear()')
                page.reload(wait_until='networkidle')
                use.click()
                expect(dialog).not_to_be_visible()
                expect(page.locator('path.user-location-dot')).to_have_count(1)
                expect(page.locator('path.user-location-accuracy')).to_have_count(1)
                expect(page.locator('.user-location-tooltip')).to_have_text('Vị trí của bạn')
                assert not any('/api/rain-route' in url for url in traffic)
                page.locator('#station-map').screenshot(path=str(OUT / f'{name}-located.png'))
                assert not errors, errors
                report['checks'].append(f'{name}: centered dark dialog, <=380px, safe margins, keyboard focus, Defer/manual entry, Use location/blue dot/accuracy, no route request')
                ctx.close()
            report['passed'] = True
        finally:
            (OUT / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding='utf-8')
            print(json.dumps(report, ensure_ascii=True, indent=2), flush=True)

        if '--keep-open' in sys.argv:
            # Fresh sessions for the user: no granted location permission, no
            # synthetic location and no test instrumentation on these pages.
            for width, height in [(1440, 1000), (390, 844)]:
                page = context(width, height).new_page()
                page.goto(BASE, wait_until='networkidle')
            print('Desktop and phone Chrome windows are ready; Flask remains running.', flush=True)
            while browser.is_connected():
                try:
                    page.wait_for_timeout(1000)
                except Exception:
                    break
        browser.close()


if __name__ == '__main__':
    main()
