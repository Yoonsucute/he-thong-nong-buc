/* Public heat/rain route comparisons use a layer below the station pins. */
"use strict";
window.HeatWatchRainRoutes = (() => {
  let initialized = false;
  function init(map) {
    const $ = (id) => document.getElementById(id);
    if (initialized || !map || !$("rain-route-form")) return;
    initialized = true;
    const lines = L.layerGroup().addTo(map), endpoints = L.layerGroup().addTo(map);
    map.createPane("rainRouteLines").style.zIndex = "420";
    const selected = { start: null, end: null };
    let generation = 0, controller = null, busy = false, picking = null, startRevision = 0;
    const timeFormat = new Intl.DateTimeFormat("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour: "2-digit", minute: "2-digit", day: "2-digit", month: "2-digit", hour12: false });
    const make = (tag, className, text) => {
      const item = document.createElement(tag);
      if (className) item.className = className;
      if (text !== undefined) item.textContent = text;
      return item;
    };
    function status(text, kind = "") {
      $("rain-route-status").textContent = text;
      $("rain-route-status").className = `route-status ${kind}`;
    }
    function clearRoute() {
      generation++;
      controller?.abort();
      controller = null;
      busy = false;
      $("find-rain-route").disabled = false;
      $("find-rain-route").textContent = "Tìm đường";
      lines.clearLayers();
      $("rain-route-cards").replaceChildren();
      $("rain-route-results").hidden = true;
    }
    function stopPicking() {
      picking = null;
      $("station-map").classList.remove("route-picking");
    }
    function drawEndpoints() {
      endpoints.clearLayers();
      for (const key of ["start", "end"]) {
        if (!selected[key]) continue;
        const badge = make("div", `route-endpoint ${key}`, key === "start" ? "A" : "B");
        const popup = make("div", "route-weather-popup", `${key === "start" ? "Điểm đi" : "Điểm đến"}: ${selected[key].label}`);
        L.marker(selected[key].point, { title: selected[key].label, icon: L.divIcon({ html: badge, className: "", iconSize: [25, 25], iconAnchor: [12, 12] }) }).bindPopup(popup).addTo(endpoints);
      }
    }
    function choose(key, choice, invalidate = true) {
      if (invalidate) clearRoute();
      if (key === "start" && !choice.automatic) startRevision++;
      selected[key] = choice;
      $("route-" + key).value = choice.label.slice(0, 200);
      $("route-" + key + "-selection").textContent = `${choice.point[0].toFixed(5)}, ${choice.point[1].toFixed(5)} · ${choice.label}`;
      $("route-" + key + "-selection").classList.add("chosen");
      $("route-" + key + "-results").replaceChildren();
      drawEndpoints();
    }
    async function getJSON(path, signal) {
      const response = await fetch(path, { headers: { Accept: "application/json" }, signal });
      const data = await response.json().catch(() => null);
      if (!response.ok || !data) throw new Error(data?.error || "Không đọc được kết quả. Vui lòng thử lại.");
      return data;
    }
    function typedCoordinate(text) {
      if (!/^\s*-?\d+(?:\.\d+)?\s*,\s*-?\d+(?:\.\d+)?\s*$/.test(text)) return null;
      const point = text.split(",").map(Number);
      return Math.abs(point[0]) <= 90 && Math.abs(point[1]) <= 180 ? point : null;
    }
    async function lookup(key, autoChoose = false) {
      if (selected[key]) return selected[key];
      const input = $("route-" + key), text = input.value.trim();
      const coordinate = typedCoordinate(text);
      if (coordinate) { choose(key, { point: coordinate, label: text }, !autoChoose); return selected[key]; }
      if (text.length < 3) throw new Error("Nhập địa chỉ ít nhất 3 ký tự hoặc tọa độ hợp lệ.");
      const choices = $("route-" + key + "-results");
      choices.replaceChildren(make("p", "", "Đang tìm địa chỉ…"));
      const lookupController = new AbortController();
      const timeout = setTimeout(() => lookupController.abort(), 18000);
      try {
        const data = await getJSON("/api/rain-route/geocode?" + new URLSearchParams({ q: text }), lookupController.signal);
        if (input.value.trim() !== text) return null;
        choices.replaceChildren();
        if (data.results.length === 1 && autoChoose) {
          choose(key, data.results[0], false);
          return selected[key];
        }
        for (const choice of data.results) {
          const button = make("button", "place-choice", choice.label);
          button.type = "button";
          button.addEventListener("click", () => { choose(key, choice); status("Đã chọn vị trí. Bấm Tìm đường khi đã chọn đủ hai điểm."); });
          choices.append(button);
        }
        if (!data.results.length) choices.append(make("p", "", "Không tìm thấy địa chỉ. Thử ghi thêm tỉnh/thành hoặc chọn trên bản đồ."));
        else status("Chọn đúng địa chỉ trong danh sách kết quả.");
        return null;
      } finally { clearTimeout(timeout); }
    }
    function duration(seconds) {
      const minutes = Math.max(1, Math.ceil(seconds / 60));
      return minutes >= 60 ? `${Math.floor(minutes / 60)} giờ ${minutes % 60} phút` : `${minutes} phút`;
    }
    function render(data) {
      const recommended = data.routes.find(route => route.id === data.recommended_route_id);
      const shortest = data.routes.find(route => route.id === data.shortest_route_id);
      const lowestRisk = data.routes.find(route => route.id === data.lowest_risk_route_id);
      const targets = data.routes;
      const featured = new Set([shortest, recommended, lowestRisk]);
      const colors = { low: "#14785d", moderate: "#c46c13", high: "#c62742", unknown: "#687887" };
      const levels = { low: "Thấp", moderate: "Cảnh báo", high: "Cao", unknown: "Chưa đủ dữ liệu" };
      const sources = { esp32: "ESP32 + SHT31", lstm: "Dự báo LSTM", open_meteo: "Ước tính từ Open-Meteo" };
      const display = (value, unit, digits = 0) => Number.isFinite(value) ? value.toFixed(digits) + unit : "—";
      const cardButtons = [];
      function draw(route, label, role, focus) {
        lines.clearLayers();
        for (const alternative of targets) {
          if (alternative !== route) L.polyline(alternative.geometry, { pane: "rainRouteLines", color: "#9a8ac1", weight: 4, dashArray: "8 7", interactive: false }).addTo(lines);
        }
        L.polyline(route.geometry, { pane: "rainRouteLines", color: "white", weight: 9, opacity: .9, interactive: false }).addTo(lines);
        for (const segment of route.segments) {
          const points = route.geometry.slice(segment.start_index, segment.end_index + 1);
          const dash = segment.risk === "unknown" || segment.heat_source === "lstm" ? "2 7" : segment.heat_source === "open_meteo" ? "9 6" : null;
          const popup = make("div", "route-weather-popup");
          popup.append(make("strong", "", label), make("div", "", "Dự kiến đi qua " + timeFormat.format(new Date(segment.passed_at)) + " · Giờ Việt Nam"));
          popup.append(make("div", "", "Nguy cơ đoạn: " + (levels[segment.risk] || levels.unknown)));
          popup.append(make("div", "", "Chỉ số nóng bức " + display(segment.heat_index, " °C", 1) + " · " + (sources[segment.heat_source] || "Chưa có nguồn")));
          if (segment.station_name) popup.append(make("div", "", segment.station_name + " · Cách điểm đánh giá " + display(segment.station_distance_km, " km", 2)));
          if (segment.measured_at) popup.append(make("div", "", "Đo lúc " + timeFormat.format(new Date(segment.measured_at)) + " · Giờ Việt Nam"));
          if (Number.isFinite(segment.temperature)) popup.append(make("div", "", "Nhiệt độ " + display(segment.temperature, " °C", 1) + " · Độ ẩm " + display(segment.humidity, "%", 1)));
          popup.append(make("div", "", "Xác suất mưa " + display(segment.probability_percent, "%") + " · " + display(segment.precipitation_mm, " mm/giờ", 1) + " · Open-Meteo"));
          L.polyline(points, { pane: "rainRouteLines", color: colors[segment.risk] || colors.unknown, weight: 6, opacity: 1, dashArray: dash, className: "rain-segment " + segment.risk }).bindPopup(popup).addTo(lines);
        }
        cardButtons.forEach(button => button.setAttribute("aria-pressed", String(button.dataset.routeRole === role)));
        const fitted = focus ? route.geometry : targets.flatMap(target => target.geometry);
        map.fitBounds(L.latLngBounds(fitted), { padding: [35, 35], maxZoom: 15 });
        if (focus) $("station-map").scrollIntoView({ behavior: "smooth", block: "center" });
      }
      const cards = $("rain-route-cards");
      cards.replaceChildren();
      function card(route, label, kind, parent = cards) {
        const item = make(route ? "button" : "article", `route-card ${kind} ${route ? "" : "unavailable"}`);
        item.append(make("h3", "", label));
        if (!route) {
          item.append(make("p", "", "Chưa đủ dữ liệu nóng bức và mưa để xếp hạng."));
        } else {
          item.type = "button";
          item.dataset.routeRole = kind;
          cardButtons.push(item);
          const stats = make("div", "route-stats");
          stats.append(make("strong", "", `${route.distance_km.toFixed(1)} km`), make("span", "", duration(route.duration_seconds)));
          item.append(stats, make("p", "", `Đến khoảng ${timeFormat.format(new Date(route.arrival_at))} · Giờ Việt Nam`));
          item.append(make("p", "route-heat-badge " + route.heat_risk, "Nóng bức " + (levels[route.heat_risk] || levels.unknown) + " · Đỉnh " + display(route.max_heat_index, " °C", 1)));
          item.append(make("p", "", "Xác suất mưa cao nhất " + display(route.max_rain_probability, "%") + " · Open-Meteo"));
          const coverage = route.heat_source_percent || {};
          const bar = make("div", "route-coverage-bar");
          bar.setAttribute("aria-hidden", "true");
          for (const [key, cls] of [["esp32", "cov-esp32"], ["lstm", "cov-lstm"], ["open_meteo", "cov-om"]]) {
            const pct = Number.isFinite(coverage[key]) ? Math.max(0, coverage[key]) : 0;
            if (pct > 0) {
              const slice = make("span", cls);
              slice.style.width = pct.toFixed(1) + "%";
              bar.append(slice);
            }
          }
          if (bar.children.length) item.append(bar);
          item.append(make("p", "", "Theo thời gian tuyến: ESP32 " + display(coverage.esp32, "%", 1) + " · LSTM " + display(coverage.lstm, "%", 1) + " · Open-Meteo " + display(coverage.open_meteo, "%", 1)));
          if (!route.heat_complete || !route.weather_complete) item.append(make("p", "", "Bao phủ: nóng bức " + display(route.heat_coverage_percent, "%", 1) + " · mưa " + display(route.weather_coverage_percent, "%", 1)));
          if (data.reasons?.[kind]) item.append(make("p", "route-reason", data.reasons[kind]));
          if (kind !== "recommended" && route === recommended) item.append(make("p", "same-route", "Trùng với tuyến phù hợp nhất"));
          item.addEventListener("click", () => draw(route, label, kind, true));
        }
        parent.append(item);
      }
      card(recommended, "Tuyến phù hợp nhất", "recommended");
      card(shortest, "Tuyến ngắn nhất", "shortest");
      card(lowestRisk, "Tuyến ít nguy cơ nóng bức và mưa", "lowest_risk");
      const otherRoutes = targets.filter(route => !featured.has(route));
      if (otherRoutes.length) {
        const more = make("details", "route-other-choices");
        more.append(make("summary", "", "Tuyến khác (" + otherRoutes.length + ")"));
        const list = make("div", "route-other-list");
        otherRoutes.forEach((route, index) => card(route, "Tuyến khác " + (index + 1), route.id, list));
        more.append(list);
        cards.append(more);
      }
      $("rain-route-results").hidden = false;
      const warnings = [...(data.warnings || [])];
      if (data.routes.length === 1) warnings.push("Chỉ tìm được một tuyến phù hợp.");
      status(`Tìm được ${data.routes.length} tuyến khác nhau · Khởi hành ${timeFormat.format(new Date(data.departure_at))} (giờ Việt Nam). ${warnings.join(" ")}`, recommended ? "" : "error");
      if (recommended || shortest) draw(recommended || shortest, recommended ? "Tuyến phù hợp nhất" : "Tuyến ngắn nhất", recommended ? "recommended" : "shortest", false);
    }
    for (const key of ["start", "end"]) {
      $("route-" + key).addEventListener("input", () => {
        if (key === "start") startRevision++;
        clearRoute(); selected[key] = null; drawEndpoints();
        $("route-" + key + "-selection").textContent = "Chưa chọn vị trí";
        $("route-" + key + "-selection").classList.remove("chosen");
        $("route-" + key + "-results").replaceChildren();
        status("Đã thay đổi điểm đi hoặc điểm đến. Chọn vị trí rồi tìm tuyến mới.");
      });
      $("search-route-" + key).addEventListener("click", async () => {
        try { await lookup(key); } catch (error) { status(error.name === "AbortError" ? "Tìm địa chỉ quá lâu. Thử lại hoặc chọn trên bản đồ." : error.message, "error"); }
      });
      $("pick-route-" + key).addEventListener("click", () => {
        stopPicking(); picking = key;
        $("station-map").classList.add("route-picking");
        status(`Chạm lên bản đồ để chọn ${key === "start" ? "điểm đi (A)" : "điểm đến (B)"}. Nhấn Esc để hủy.`);
        $("station-map").scrollIntoView({ behavior: "smooth", block: "center" });
      });
    }
    $("use-my-location-start").addEventListener("click", async () => {
      const revision = startRevision;
      const button = $("use-my-location-start");
      button.disabled = true;
      try {
        const location = window.HeatWatchLocation?.getPosition() || await window.HeatWatchLocation?.requestPosition({ focusMap: false });
        if (!location) { status("Chưa lấy được vị trí. Bạn vẫn có thể nhập hoặc chọn điểm đi thủ công."); return; }
        if (revision !== startRevision) { status("Đã giữ điểm đi bạn vừa sửa. Bấm Dùng vị trí của tôi nếu muốn thay lại."); return; }
        choose("start", { point: [location.latitude, location.longitude], label: "Vị trí của tôi" });
        status("Đã chọn vị trí của bạn làm điểm đi. Bạn có thể sửa lại; tọa độ chỉ được gửi khi bấm Tìm đường.");
      } finally { button.disabled = false; }
    });
    map.on("click", (event) => {
      if (!picking || event.originalEvent?.target?.closest?.(".leaflet-marker-icon, .leaflet-popup, .leaflet-control")) return;
      const point = [Number(event.latlng.lat.toFixed(6)), Number(event.latlng.lng.toFixed(6))];
      choose(picking, { point, label: point.join(", ") });
      stopPicking();
      status("Đã chọn điểm trên bản đồ. Bấm Tìm đường khi đã chọn đủ hai điểm.");
      $("rain-planner").scrollIntoView({ behavior: "smooth", block: "start" });
    });
    document.addEventListener("keydown", (event) => { if (event.key === "Escape" && picking) { stopPicking(); status("Đã hủy chọn điểm trên bản đồ."); } });
    function refreshTimeBounds() {
      const local = (date) => new Date(date.getTime() + 7 * 3600000).toISOString().slice(0, 16);
      $("route-departure").min = local(new Date());
      $("route-departure").max = local(new Date(Date.now() + 6 * 86400000));
    }
    $("route-departure-mode").addEventListener("change", () => {
      clearRoute(); refreshTimeBounds();
      const scheduled = $("route-departure-mode").value === "scheduled";
      $("route-time-label").hidden = !scheduled;
      $("route-departure").disabled = !scheduled;
      $("route-departure").required = scheduled;
      status("Đã thay đổi giờ khởi hành. Bấm tìm để đánh giá lại tuyến.");
    });
    for (const id of ["route-vehicle", "route-departure"]) $(id).addEventListener("change", () => { clearRoute(); status("Đã thay đổi lựa chọn. Bấm tìm để đánh giá lại tuyến."); });
    $("clear-rain-route").addEventListener("click", () => { clearRoute(); stopPicking(); status("Đã xóa các tuyến. Ghim trạm đo vẫn được giữ trên bản đồ."); });
    $("rain-route-form").addEventListener("submit", async (event) => {
      event.preventDefault();
      if (busy || !$("rain-route-form").reportValidity()) return;
      startRevision++; // A late location result must not replace a submitted origin.
      stopPicking(); clearRoute(); busy = true;
      const requestGeneration = generation;
      $("find-rain-route").disabled = true;
      $("find-rain-route").textContent = "Đang tìm tuyến…";
      status("Đang tìm tuyến và đánh giá nóng bức, mưa theo giờ đi qua…", "busy");
      try {
        const locations = await Promise.all([lookup("start", true), lookup("end", true)]);
        if (generation !== requestGeneration) return;
        if (locations.some(point => !point)) { status("Chọn đúng địa chỉ trong kết quả tìm kiếm cho cả điểm đi và điểm đến."); return; }
        const scheduled = $("route-departure-mode").value === "scheduled";
        const departure = scheduled ? $("route-departure").value + ":00+07:00" : "now";
        const params = new URLSearchParams({ start: selected.start.point.join(","), end: selected.end.point.join(","), vehicle: $("route-vehicle").value, departure });
        controller = new AbortController();
        const timeout = setTimeout(() => controller?.abort(), 80000);
        let data;
        try { data = await getJSON("/api/rain-route?" + params, controller.signal); }
        finally { clearTimeout(timeout); }
        if (generation !== requestGeneration) return;
        render(data);
      } catch (error) {
        if (generation === requestGeneration) status(error.name === "AbortError" ? "Dịch vụ phản hồi quá lâu. Thử tìm lại sau." : error.message, "error");
      } finally {
        if (generation === requestGeneration) {
          busy = false; controller = null;
          $("find-rain-route").disabled = false;
          $("find-rain-route").textContent = "Tìm đường";
        }
      }
    });
    refreshTimeBounds();
    return (location) => {
      if (startRevision !== 0 || ($("route-start").value.trim() && !selected.start?.automatic)) return;
      if (selected.start?.point[0] === location.latitude && selected.start.point[1] === location.longitude) return;
      choose("start", {
        point: [location.latitude, location.longitude], label: "Vị trí của tôi", automatic: true,
      });
    };
  }
  return { init };
})();
