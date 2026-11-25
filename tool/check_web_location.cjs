// Runs the actual dashboard.js with minimal DOM/Leaflet test doubles.
// Uses snapshots from the real MQTT/MySQL/HTTP check. This is not a browser test.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const root = path.resolve(__dirname, '..');
const publicView = process.argv.includes('--public');
const adminIds = new Set(['admin-csrf', 'device-rows', 'device-dialog', 'add-device', 'close-dialog', 'cancel-dialog', 'device-form']);
const evidence = JSON.parse(fs.readFileSync(path.join(root, 'build/location-check/mqtt-result.json'), 'utf8'));
assert.equal(evidence.passed, true);
class Element {
  constructor() { this.children = []; this.classList = { toggle() {}, add() {}, remove() {} }; }
  append(...children) { this.children.push(...children); }
  replaceChildren(...children) { this.children = children; }
  addEventListener() {}
  setAttribute() {}
  closest() { return null; }
}
const elements = new Map();
const element = id => {
  if (publicView && adminIds.has(id)) return null;
  if (!publicView && id === 'public-current') return null;
  if (!elements.has(id)) elements.set(id, new Element());
  if (id === 'admin-csrf') elements.get(id).content = 'test-csrf-token';
  if (id === 'public-current') elements.get(id).dataset = { public: 'true' };
  return elements.get(id);
};
const group = { layers: new Set(), addTo() { return this; }, removeLayer(m) { this.layers.delete(m); } };
const imageryUrls = [], islandLabels = [], panes = new Map();
let fits = 0, created = 0, completed = 0, poll;
let rows = [];
const L = {
  map: () => ({ setView() { return this; }, fitBounds() { fits++; }, createPane(name) { const pane = {style: {}}; panes.set(name, pane); return pane; } }),
  tileLayer: url => { imageryUrls.push(url); return { on() { return this; }, addTo() { return this; } }; },
  layerGroup: () => group, divIcon: options => options, latLngBounds: points => points,
  marker(point, options) {
    if (options.interactive !== false) created++;
    else islandLabels.push({ point, options });
    return { point, options, element: new Element(),
      bindPopup(popup) { this.popup = popup; return this; },
      addTo(target) { target.layers?.add(this); return this; },
      setLatLng(p) { this.point = p; return this; },
      setIcon(icon) { this.options.icon = icon; return this; },
      setPopupContent(popup) { this.popup = popup; return this; },
      getElement() { return this.element; } };
  },
};
const document = { getElementById: element, createElement: () => new Element(),
  querySelectorAll: () => [], addEventListener() {}, hidden: false };
const context = { document, window: { L, addEventListener() {} }, L, console, Intl, Date, URLSearchParams, AbortController,
  setTimeout, clearTimeout, setInterval(callback, ms) { assert.equal(ms, 15000); poll = callback; },
  async fetch(url) {
    const body = url === '/api/devices' ? structuredClone(rows) : [];
    // /api/alerts is always requested once per selected-device refresh.
    if (url.startsWith('/api/alerts')) completed++;
    return { ok: true, json: async () => body };
  } };
vm.runInNewContext(fs.readFileSync(path.join(root, 'backend/static/dashboard.js'), 'utf8'), context);
const settle = async () => { for (let i = 0; i < 12; i++) await new Promise(resolve => setImmediate(resolve)); };
const text = node => [node.textContent || '', ...(node.children || []).map(text)].join(' ');
(async () => {
  await settle();
  assert.equal(imageryUrls.length, 1);
  assert.match(imageryUrls[0], /\/World_Imagery\/MapServer\/tile\//);
  assert.deepEqual(islandLabels.map(m => m.options.icon.html.textContent), ['Hoàng Sa', 'Trường Sa']);
  assert.ok(islandLabels.every(m => m.options.interactive === false && m.options.keyboard === false));
  assert.equal(panes.get('vietnameseIslandLabels').style.pointerEvents, 'none');
  assert.equal(panes.get('vietnameseIslandLabels').style.zIndex, '450');
  assert.equal(group.layers.size, 0);
  let original;
  for (const stage of evidence.stages.slice(1)) {
    rows = stage.devices;
    poll(); // Invoke the exact 15-second timer callback, without reloading script.
    await settle();
    const d = rows[0];
    assert.equal(group.layers.size, d.latitude === null ? 0 : 1);
    if (d.latitude === null) {
      assert.match(text(element(publicView ? 'station-list' : 'device-rows')), /Đang định vị/);
    } else {
      const marker = [...group.layers][0];
      assert.equal(marker.point[0], d.latitude);
      assert.equal(marker.point[1], d.longitude);
      assert.match(text(marker.popup), /Vị trí ước lượng qua mạng 4G/);
      if (!original) original = marker;
      assert.equal(marker, original, 'same device must update the existing marker');
      if (d.location_pending) assert.match(text(marker.popup), /Vị trí gần nhất/);
    }
    assert.equal(element('global-error').hidden, true);
    console.log('PASS web timer + map: ' + stage.name);
  }
  assert.equal(created, 1);
  assert.equal(fits, 1);
  assert.ok(completed >= 5);
  console.log(`PASS ${publicView ? 'public' : 'admin'}: one marker, first-fix camera fit, updates without page reload (DOM/Leaflet doubles).`);
})().catch(error => { console.error(error); process.exitCode = 1; });
