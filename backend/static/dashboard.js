/* HeatWatch: same-origin Flask REST client. No demo values are substituted. */
"use strict";

(() => {
  const $ = (id) => document.getElementById(id);
  const csrfToken = $("admin-csrf")?.content || "";
  const publicView = $("public-current")?.dataset?.public === "true";
  const state = {
    devices: [], selectedId: "", history: [], alerts: [], busy: false, queued: false,
    generation: 0, editingId: null, forecastStationId: null, historyChart: null, forecastChart: null,
    filters: { limit: publicView ? "500" : "100", start: "", end: "", hours: 3, date: "" }, map: null, markers: null, thermalLayer: null, showThermal: true,
    deviceMarkers: new Map(), hasFittedLocations: false, search: "",
    alertSource: null, alertSound: false, alertNotify: false, alertBannerTimer: null,
  };
  const timeZone = "Asia/Ho_Chi_Minh";
  const clockFormat = new Intl.DateTimeFormat("vi-VN", { timeZone, hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });
  const dateFormat = new Intl.DateTimeFormat("vi-VN", { timeZone, day: "2-digit", month: "2-digit", year: "numeric" });
  const shortClock = new Intl.DateTimeFormat("vi-VN", { timeZone, hour: "2-digit", minute: "2-digit", hour12: false });
  function todayIsoDate() {
    const parts = new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).formatToParts(new Date());
    const map = Object.fromEntries(parts.map((p) => [p.type, p.value]));
    return `${map.year}-${map.month}-${map.day}`;
  }
  let toastTimer;

  function node(tag, className = "", value) {
    const element = document.createElement(tag);
    if (className) element.className = className;
    if (value !== undefined) element.textContent = String(value);
    return element;
  }
  function numeric(value) {
    if (!["number", "string"].includes(typeof value) || (typeof value === "string" && !value.trim())) return null;
    const result = Number(value);
    return Number.isFinite(result) ? result : null;
  }
  function measure(value, suffix = "") {
    const result = numeric(value);
    return result === null ? "—" : `${result.toFixed(1)}${suffix}`;
  }
  function parseTime(value) {
    if (!value) return null;
    if (value instanceof Date) return Number.isNaN(value.getTime()) ? null : value;
    let normalized = String(value).replace(" ", "T");
    if (/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?$/.test(normalized)) normalized += "+07:00";
    const result = new Date(normalized);
    return Number.isNaN(result.getTime()) ? null : result;
  }
  function timeText(value, short = false) {
    const date = parseTime(value);
    return date ? (short ? shortClock.format(date) : `${clockFormat.format(date)} · ${dateFormat.format(date)}`) : "Chưa có bản đo";
  }
  function relativeTime(value) {
    const date = parseTime(value);
    if (!date) return "Chưa có bản đo";
    const seconds = Math.max(0, Math.floor((Date.now() - date.getTime()) / 1000));
    if (seconds < 60) return `Cập nhật ${seconds < 5 ? "vừa xong" : `${seconds} giây trước`}`;
    if (seconds < 3600) return `Cập nhật ${Math.floor(seconds / 60)} phút trước`;
    if (seconds < 86400) return `Cập nhật ${Math.floor(seconds / 3600)} giờ trước`;
    return `Cập nhật ${Math.floor(seconds / 86400)} ngày trước`;
  }
  function trustedPosition(device, now = Date.now()) {
    if (!device || device.location_status === "unavailable") return null;
    const latitude = numeric(device.latitude), longitude = numeric(device.longitude);
    const source = device.location_source;
    const updatedAt = parseTime(device.location_updated_at);
    if (latitude === null || longitude === null || Math.abs(latitude) > 90 || Math.abs(longitude) > 180 ||
        (latitude === 0 && longitude === 0) ||
        !["manual", "lbs", "gnss", "gps"].includes(source) || !updatedAt) return null;
    const age = (now - updatedAt.getTime()) / 1000;
    if (age < -30) return null;
    const status = source === "manual" ? "manual" : device.location_pending || device.is_online === false || device.location_status === "last_known"
      ? "last_known" : source === "lbs"
      ? (age <= 600 ? "estimated" : "last_known") : (age <= 120 ? "current" : "last_known");
    return { latitude, longitude, source, updatedAt, status };
  }
  function locationText(device) {
    const position = trustedPosition(device);
    if (!position) return device?.gps_valid === false ? "Chưa bắt được GPS" : "Đang định vị";
    const description = ({ lbs: "Vị trí ước lượng qua mạng 4G", gnss: "Vị trí GPS/GNSS", gps: "GPS ATGM336H", manual: "Vị trí lắp đặt được nhập" })[position.source];
    const fix = device.gps_valid === false ? " · Chưa bắt được GPS" :
      position.status === "current" && Number.isInteger(device.satellites) ? ` · ${device.satellites} vệ tinh` : "";
    return `${position.status === "last_known" ? "Vị trí gần nhất · " : ""}${description}${fix} · ${timeText(position.updatedAt)}`;
  }
  function warning(value) {
    const heat = numeric(value?.heat_index);
    const level = ["normal", "caution", "danger"].includes(value?.warning_level)
      ? value.warning_level : heat === null ? "neutral" : heat >= 38 ? "danger" : heat >= 32 ? "caution" : "normal";
    return { level, label: ({ normal: "✓ An toàn", caution: "△ Cảnh báo nóng", danger: "⚠ Cực kỳ nguy hiểm", neutral: "Chưa có dữ liệu" })[level] };
  }
  function badge(label, level) { return node("span", `badge-status ${level}`, label); }
  function message(id, text, error = false) {
    const target = $(id);
    if (!target) return;
    target.textContent = text;
    target.classList.toggle("error", error);
  }
  function emptyRow(targetId, columns, text) {
    const row = node("tr");
    const cell = node("td", "empty-cell", text);
    cell.colSpan = columns;
    row.append(cell);
    $(targetId).replaceChildren(row);
  }
  function toast(text) {
    $("toast-message").textContent = text;
    $("toast-message").hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => { $("toast-message").hidden = true; }, 4500);
  }
  async function api(path, options = {}) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 18000);
    try {
      const response = await fetch(path, { ...options, headers: { "Accept": "application/json", ...(options.body ? { "Content-Type": "application/json" } : {}), ...(csrfToken && options.method ? { "X-CSRF-Token": csrfToken } : {}) }, signal: controller.signal });
      const data = await response.json().catch(() => null);
      if (!response.ok) {
        const error = new Error(data?.error || `Máy chủ trả về lỗi ${response.status}.`);
        error.code = data?.code;
        error.status = response.status;
        throw error;
      }
      if (data === null) throw new Error("Máy chủ trả về dữ liệu không hợp lệ.");
      return data;
    } catch (error) {
      if (error.name === "AbortError") throw new Error("Máy chủ phản hồi quá lâu. Hãy thử làm mới.");
      throw error;
    } finally { clearTimeout(timeout); }
  }

  function renderDevices() {
    renderStationList();
    const active = state.devices.filter((device) => device.enabled);
    $("total-devices").textContent = String(active.length);
    $("online-count").textContent = `${active.filter((device) => device.is_online).length} đang kết nối${publicView ? "" : ` · ${state.devices.length - active.length} đã tắt`}`;
    const warnings = active.filter((device) => device.latest && warning(device.latest).level !== "normal" && warning(device.latest).level !== "neutral").length;
    $("warning-count").textContent = String(warnings);
    const navAlert = $("nav-alert-count");
    if (navAlert) {
      navAlert.textContent = warnings > 99 ? "99+" : String(warnings);
      if (publicView) navAlert.hidden = warnings <= 0;
    }
    const select = $("device-select");
    const options = (publicView ? active : state.devices).map((device) => {
      const option = node("option", "", `${device.name || device.device_id}${device.enabled ? "" : " · Đã tắt"}`);
      option.value = device.device_id;
      return option;
    });
    if (!options.length) {
      const option = node("option", "", "Chưa có thiết bị");
      option.value = "";
      options.push(option);
    }
    select.replaceChildren(...options);
    select.value = state.selectedId;
    select.disabled = !(publicView ? active : state.devices).length;
    const historySelect = $("history-device-select");
    if (historySelect) {
      historySelect.replaceChildren(...options.map((opt) => opt.cloneNode(true)));
      historySelect.value = state.selectedId;
      historySelect.disabled = select.disabled;
    }
    if (!$("device-rows")) return;
    if (!state.devices.length) {
      emptyRow("device-rows", 6, "Bật ESP32 có kết nối MQTT. Thiết bị sẽ tự đăng ký khi gửi dữ liệu.");
      return;
    }
    const rows = state.devices.map((device) => {
      const row = node("tr");
      const name = node("td");
      const open = node("button", "text-button device-name", device.name || device.device_id);
      open.type = "button";
      open.addEventListener("click", () => selectDevice(device.device_id, true));
      name.append(open, node("span", "device-id", device.device_id));
      const coordinates = node("td", "coordinate");
      const position = trustedPosition(device);
      coordinates.textContent = position ? `${position.latitude.toFixed(5)}, ${position.longitude.toFixed(5)}` : locationText(device);
      if (position) coordinates.append(node("span", "device-id", locationText(device)));
      const heat = node("td", "", measure(device.latest?.heat_index, " °C"));
      const status = node("td");
      status.append(badge(!device.enabled ? "Đã tắt" : device.is_online ? "Đang kết nối" : "Mất kết nối", !device.enabled || !device.is_online ? "neutral" : "normal"));
      const last = node("td", "", timeText(device.last_seen));
      const actions = node("td");
      const controls = node("div", "device-actions");
      const edit = node("button", "text-button", "Sửa");
      edit.type = "button";
      edit.setAttribute("aria-label", `Sửa ${device.name || device.device_id}`);
      edit.addEventListener("click", () => openDeviceDialog(device));
      controls.append(edit);
      if (device.enabled) {
        const disable = node("button", "text-button danger", "Tạm ngưng");
        disable.type = "button";
        disable.setAttribute("aria-label", `Tạm ngưng ${device.name || device.device_id}`);
        disable.addEventListener("click", () => disableDevice(device, disable));
        controls.append(disable);
      }
      actions.append(controls);
      row.append(name, coordinates, heat, status, last, actions);
      return row;
    });
    $("device-rows").replaceChildren(...rows);
  }

  function renderStationList() {
    const query = state.search.trim().toLocaleLowerCase("vi");
    const devices = state.devices.filter(device => device.enabled &&
      `${device.name || ""} ${device.device_id}`.toLocaleLowerCase("vi").includes(query));
    $("station-result-count").textContent = String(devices.length);
    const cards = devices.map(device => {
      const level = warning(device.latest);
      const card = node("button", `station-item ${level.level} ${device.is_online ? "" : "offline"} ${device.device_id === state.selectedId ? "selected" : ""}`);
      card.type = "button";
      card.setAttribute("role", "listitem");
      card.setAttribute("aria-label", `${device.name || device.device_id}, ${device.is_online ? "đang kết nối" : "mất kết nối"}, ${level.label}`);
      const top = node("div", "station-item-heading");
      top.append(node("strong", "", device.name || device.device_id), node("b", "station-number", measure(device.latest?.heat_index, "°")));
      const status = node("div", "station-status-line");
      status.append(node("span", "status-label", device.is_online ? "● Đang kết nối" : "○ Mất kết nối"), node("span", "", trustedPosition(device) ? level.label : "Đang định vị"));
      const metrics = node("div", "station-mini-metrics");
      if (device.latest) {
        metrics.append(
          node("span", "station-mini-chip", `Nhiệt độ ${measure(device.latest.temperature, "°C")}`),
          node("span", "station-mini-chip", `Độ ẩm ${measure(device.latest.humidity, "%")}`),
        );
      }
      card.append(top, node("span", "station-caption", `${device.device_id} · ${relativeTime(device.last_seen)}`));
      if (metrics.children.length) card.append(metrics);
      card.append(status);
      card.addEventListener("click", () => {
        void selectDevice(device.device_id, false);
        const position = trustedPosition(device);
        if (position && state.map) {
          state.map.setView([position.latitude, position.longitude], 12, { animate: false });
          if (!publicView) state.deviceMarkers.get(device.device_id)?.openPopup();
          if (publicView && window.innerWidth < 800) $("public-current").scrollIntoView({ behavior: "smooth", block: "start" });
          else if (!publicView && window.innerWidth < 980) $("station-map").scrollIntoView({ behavior: "smooth", block: "center" });
        } else if (publicView) $("public-current").scrollIntoView({ behavior: "smooth", block: "start" });
        else $("station-detail").scrollIntoView({ behavior: "smooth", block: "start" });
      });
      return card;
    });
    $("station-list").replaceChildren(...(cards.length ? cards : [node("p", "section-message", query ? "Không tìm thấy trạm. Thử tên hoặc mã khác." : "Chưa có điểm đo. Thiết bị sẽ tự xuất hiện khi gửi dữ liệu.")]));
  }

  function heatSpectrumPercent(heat) {
    if (heat === null) return null;
    if (heat <= 32) return Math.max(2, Math.min(47.6, ((heat - 20) / 12) * 47.6));
    if (heat <= 38) return 47.6 + ((heat - 32) / 6) * 28.6;
    return Math.min(98, 76.2 + ((heat - 38) / 6) * 23.8);
  }

  function renderReading(device) {
    if (publicView) window.HeatWatchWeather?.setStation(device, trustedPosition(device));
    const forecastStation = publicView && $("weather-forecast-station");
    if (forecastStation) {
      const id = device?.device_id || "";
      if (state.forecastStationId !== id) {
        $("weather-hours").hidden = true;
        message("weather-forecast-message", id ? "Đang tải dự báo 5 giờ tới…" : "Chưa có điểm đo để xem dự báo.");
      }
      state.forecastStationId = id;
      forecastStation.hidden = !id;
      forecastStation.textContent = id ? (device.name || id) : "";
    }
    $("detail-station-name").textContent = device ? device.name || device.device_id : "Chi tiết điểm đo";
    const reading = device?.latest;
    $("temperature").textContent = measure(reading?.temperature);
    $("humidity").textContent = measure(reading?.humidity);
    $("heat-index").textContent = measure(reading?.heat_index);
    $("reading-warning").textContent = warning(reading).label;
    $("reading-update").textContent = reading ? `${relativeTime(reading.created_at)} · ${timeText(reading.created_at)}${publicView ? "" : ` · ${locationText(device)}`}` : "Chưa có số đo. Đang chờ thiết bị gửi dữ liệu.";
    $("heat-index").closest(".reading-card")?.setAttribute("class", `reading-card heat-index ${warning(reading).level}`);
    const scaleMarker = publicView && $("heat-scale-marker");
    if (scaleMarker && scaleMarker.style) {
      const pct = heatSpectrumPercent(numeric(reading?.heat_index));
      scaleMarker.hidden = pct === null;
      if (pct !== null) scaleMarker.style.left = `${pct.toFixed(1)}%`;
    }
    const humFill = publicView && $("humidity-bar-fill");
    if (humFill && humFill.style) {
      const hum = numeric(reading?.humidity);
      humFill.style.width = `${hum === null ? 0 : Math.max(0, Math.min(100, hum))}%`;
    }
    const online = device?.enabled && device?.is_online;
    $("station-status").textContent = !device ? "Chưa chọn điểm đo" : !device.enabled ? "Thiết bị đã tắt" : online ? (publicView ? "Đang đo trực tiếp" : "Đang kết nối") : (publicView ? "Tạm ngừng gửi · Số đo gần nhất" : "Mất kết nối · Bản đo gần nhất");
    $("station-status").className = `badge-status ${online ? "normal" : "neutral"}`;
    if ($("history-subtitle")) $("history-subtitle").textContent = device
      ? (publicView ? `Trạm ${device.name || device.device_id} · Diễn biến nhiệt độ và độ ẩm gần đây` : `Điểm đo: ${device.name || device.device_id} · Thời gian Việt Nam (UTC+7)`)
      : "Dữ liệu của điểm đo đang chọn.";
  }

  function initMap() {
    if (!window.L) {
      $("station-map").replaceChildren(node("div", "map-loading", "Không tải được thư viện bản đồ. Kiểm tra Internet rồi tải lại trang."));
      if (publicView) window.HeatWatchLocation?.init(null);
      return;
    }
    $("station-map").replaceChildren();
    state.map = L.map("station-map", { scrollWheelZoom: false }).setView([13, 109], 5);
    // Imagery only. Do not add Reference/World_Boundaries_and_Places,
    // World_Transportation or a hybrid basemap: those add place-name labels.
    L.tileLayer("https://services.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}", {
      maxZoom: 19, attribution: "Ảnh © Esri, Maxar, Earthstar Geographics, GIS User Community",
    }).on("tileerror", () => { $("station-map").setAttribute("aria-label", "Bản đồ đang gặp lỗi tải ảnh vệ tinh. Kiểm tra kết nối Internet."); }).addTo(state.map);
    state.thermalLayer = L.layerGroup().addTo(state.map);
    state.markers = L.layerGroup().addTo(state.map);
    const islandPane = state.map.createPane("vietnameseIslandLabels");
    islandPane.style.zIndex = "450"; // Above imagery, below ESP32 marker/popup panes.
    islandPane.style.pointerEvents = "none";
    for (const [point, label] of [[[16.5414, 111.6853], "Hoàng Sa"], [[8.6444, 111.9192], "Trường Sa"]]) {
      const title = node("div", "island-label", label);
      L.marker(point, { pane: "vietnameseIslandLabels", icon: L.divIcon({ html: title, className: "", iconSize: [92, 28], iconAnchor: [46, 14] }), interactive: false, keyboard: false }).addTo(state.map);
    }
    if (publicView) {
      const useDefaultOrigin = window.HeatWatchRainRoutes?.init(state.map);
      window.HeatWatchLocation?.init(state.map, (position) => {
        state.hasFittedLocations = true;
        useDefaultOrigin?.(position);
      });
    }
  }
  function renderMap() {
    const active = state.devices.filter((entry) => entry.enabled);
    const located = active.map((device) => ({ device, position: trustedPosition(device) })).filter((entry) => entry.position);
    const mapMessage = !active.length ? "Chưa có thiết bị đang theo dõi." : !located.length
      ? "Chưa nhận được vị trí thực từ thiết bị. Bản đồ chưa có ghim ESP32; đang chờ kết quả định vị hợp lệ."
      : `${located.length}/${active.length} thiết bị có vị trí. Mở ghim để xem nguồn và trạng thái định vị của trạm.`;
    $("map-location-message").textContent = mapMessage;
    $("station-map").setAttribute("aria-label", `Bản đồ vị trí thiết bị. ${mapMessage}`);
    if (!state.map || !state.markers) return;
    state.thermalLayer?.clearLayers();
    const ids = new Set(located.map(({ device }) => device.device_id));
    for (const [id, marker] of state.deviceMarkers) {
      if (!ids.has(id)) { state.markers.removeLayer(marker); state.deviceMarkers.delete(id); }
    }
    for (const { device, position } of located) {
      const heatLevel = warning(device.latest).level;
      if (state.showThermal && state.thermalLayer) {
        const thermalColor = heatLevel === "danger" ? "#ef4444" : heatLevel === "caution" ? "#f59e0b" : heatLevel === "normal" ? "#14b8a6" : "#64748b";
        L.circle([position.latitude, position.longitude], {
          radius: 450, color: thermalColor, fillColor: thermalColor,
          fillOpacity: 0.16, weight: 1.5, opacity: 0.48, interactive: false,
        }).addTo(state.thermalLayer);
        L.circle([position.latitude, position.longitude], {
          radius: 170, color: thermalColor, fillColor: thermalColor,
          fillOpacity: 0.24, weight: 0, interactive: false,
        }).addTo(state.thermalLayer);
      }
      const pin = node("div", `station-pin ${device.is_online && position.status !== "last_known" ? warning(device.latest).level : "offline"}`);
      const popup = node("div");
      popup.append(node("div", "popup-title", device.name || device.device_id));
      popup.append(node("div", "popup-line", device.is_online ? "● Đang kết nối" : "○ Mất kết nối · Số đo gần nhất"));
      popup.append(node("div", `popup-heat ${warning(device.latest).level}`, measure(device.latest?.heat_index, "°C")));
      popup.append(node("div", "popup-line", `Chỉ số nóng bức · ${warning(device.latest).label}`));
      const stats = node("div", "popup-stats");
      for (const [label, value] of [["Nhiệt độ", measure(device.latest?.temperature, " °C")], ["Độ ẩm", measure(device.latest?.humidity, "%")]]) {
        const item = node("span", "", label); item.append(node("strong", "", value)); stats.append(item);
      }
      popup.append(stats, node("div", "popup-line", relativeTime(device.last_seen)));
      popup.append(node("div", "popup-line", locationText(device)));
      const button = node("button", "btn btn-primary btn-sm popup-button", "Xem chi tiết");
      button.type = "button";
      button.addEventListener("click", () => { void selectDevice(device.device_id, false); state.map?.closePopup(); showStationDetails(); });
      popup.append(button);
      const icon = L.divIcon({ html: pin, className: "", iconSize: [18, 18], iconAnchor: [9, 9] });
      const title = `${device.name || device.device_id} · ${locationText(device)}`;
      let marker = state.deviceMarkers.get(device.device_id);
      if (marker) {
        marker.setLatLng([position.latitude, position.longitude]).setIcon(icon).setPopupContent(popup);
        marker.options.title = title;
        marker.getElement()?.setAttribute("title", title);
      } else {
        marker = L.marker([position.latitude, position.longitude], { title, icon }).bindPopup(popup, { maxWidth: 260, maxHeight: 280, autoPanPadding: [12, 12] }).addTo(state.markers);
        if (publicView) marker.on?.("click", () => { void selectDevice(device.device_id, false); });
        state.deviceMarkers.set(device.device_id, marker);
      }
    }
    if (located.length && !state.hasFittedLocations) {
      fitMap();
      state.hasFittedLocations = true;
    }
  }
  function fitMap() {
    if (!state.map) return;
    const points = state.devices.filter((device) => device.enabled).map((device) => trustedPosition(device)).filter(Boolean).map((position) => [position.latitude, position.longitude]);
    if (points.length) state.map.fitBounds(L.latLngBounds(points), { padding: [40, 40], maxZoom: 13 });
    else state.map.setView([13, 109], 5);
  }

  function areaGradient(ctx, colorTop, colorBottom) {
    const area = ctx.chart?.chartArea;
    if (!area) return colorTop;
    const gradient = ctx.chart.ctx.createLinearGradient(0, area.top, 0, area.bottom);
    gradient.addColorStop(0, colorTop);
    gradient.addColorStop(1, colorBottom);
    return gradient;
  }
  const heatThresholdsPlugin = {
    id: "heatThresholds",
    beforeDatasetsDraw(chart) {
      const yScale = chart.scales?.y;
      const area = chart.chartArea;
      if (!yScale || !area) return;
      const ctx = chart.ctx;
      for (const [val, color, label] of [[32, "rgba(217,119,6,0.55)", "32°C Cảnh báo"], [38, "rgba(220,38,38,0.55)", "38°C Nguy hiểm"]]) {
        if (val < yScale.min || val > yScale.max) continue;
        const y = yScale.getPixelForValue(val);
        ctx.save();
        ctx.strokeStyle = color;
        ctx.lineWidth = 1.25;
        ctx.setLineDash([5, 5]);
        ctx.beginPath();
        ctx.moveTo(area.left, y);
        ctx.lineTo(area.right, y);
        ctx.stroke();
        ctx.fillStyle = color;
        ctx.font = "600 10px 'Be Vietnam Pro', 'Segoe UI', sans-serif";
        ctx.textAlign = "right";
        ctx.fillText(label, area.right - 6, y - 5);
        ctx.restore();
      }
    },
  };
  function isDarkTheme() {
    return Boolean(document.body?.classList?.contains("theme-dark"));
  }
  function chartOptions() {
    const reduceMotion = window.matchMedia?.("(prefers-reduced-motion: reduce)")?.matches;
    const dark = isDarkTheme();
    const tickColor = dark ? "#93a8c3" : "#68829e";
    const gridColor = dark ? "#223454" : "#e8f1f9";
    const legendColor = dark ? "#d2e1f2" : "#3b5672";
    return {
      responsive: true,
      maintainAspectRatio: false,
      animation: reduceMotion ? false : { duration: 350 },
      interaction: { mode: "index", intersect: false },
      plugins: {
        legend: {
          position: "bottom",
          labels: { usePointStyle: true, boxWidth: 7, padding: 18, color: legendColor, font: { size: 11, weight: "600" } },
        },
        tooltip: {
          backgroundColor: dark ? "#0b1221" : "#0f2942",
          titleColor: "#e2f0ff",
          bodyColor: "#ffffff",
          borderColor: "rgba(45, 212, 191, 0.5)",
          borderWidth: 1,
          padding: 11,
          cornerRadius: 10,
          displayColors: true,
        },
      },
      scales: {
        x: { grid: { display: false }, ticks: { maxTicksLimit: 8, color: tickColor, font: { size: 10 } }, border: { display: false } },
        y: {
          title: { display: true, text: "°C", color: tickColor, font: { size: 11, weight: "600" } },
          grid: { color: gridColor },
          border: { display: false },
          ticks: { color: tickColor, font: { size: 10 } },
        },
      },
    };
  }
  function renderHistory(rows) {
    state.history = rows;
    if (!$("history-rows")) return;
    if ($("export-history")) $("export-history").disabled = !rows.length;
    if (state.historyChart) { state.historyChart.destroy(); state.historyChart = null; }
    if ($("history-chart-wrap")) $("history-chart-wrap").hidden = !rows.length || !window.Chart;
    const statsWrap = $("history-summary-stats");
    if (statsWrap) {
      const heatVals = rows.map((row) => numeric(row.heat_index)).filter((v) => v !== null);
      statsWrap.hidden = !heatVals.length;
      if (heatVals.length) {
        const minV = Math.min(...heatVals);
        const maxV = Math.max(...heatVals);
        const avgV = heatVals.reduce((sum, v) => sum + v, 0) / heatVals.length;
        $("history-min").textContent = `${minV.toFixed(1)} °C`;
        $("history-avg").textContent = `${avgV.toFixed(1)} °C`;
        $("history-max").textContent = `${maxV.toFixed(1)} °C`;
      }
    }
    const dateLabel = state.filters.date ? state.filters.date.split("-").reverse().join("/") : "";
    const publicHistoryMsg = rows.length
      ? (dateLabel ? `Hiển thị ${rows.length} lần đo trong ngày ${dateLabel}.` : `Hiển thị ${rows.length} lần đo trong ${state.filters.hours || 3} giờ gần nhất.`)
      : (dateLabel ? `Không có dữ liệu đo trong ngày ${dateLabel}.` : "Chưa có dữ liệu lịch sử trong khoảng thời gian này.");
    message("history-message", publicView ? publicHistoryMsg : (rows.length ? `${rows.length} bản ghi theo bộ lọc đã áp dụng${window.Chart ? "" : " · Không tải được thư viện biểu đồ; dữ liệu vẫn hiển thị trong bảng."}.` : "Chưa có dữ liệu lịch sử trong khoảng thời gian này."));
    if (!rows.length) {
      if (publicView) $("history-rows").replaceChildren();
      else emptyRow("history-rows", 5, "Chưa có dữ liệu phù hợp");
      return;
    }
    if (window.Chart) {
      const options = chartOptions();
      options.scales.humidity = { position: "right", min: 0, max: 100, grid: { display: false }, border: { display: false }, ticks: { color: "#4d78b8", font: { size: 10 } }, title: { display: true, text: "%", color: "#4d78b8", font: { size: 11, weight: "600" } } };
      state.historyChart = new Chart($("history-chart"), {
        type: "line",
        data: {
          labels: rows.map((row) => timeText(row.created_at, true)),
          datasets: [
            {
              label: "Chỉ số nóng bức (°C)",
              data: rows.map((row) => numeric(row.heat_index)),
              borderColor: "#0ea5a4",
              backgroundColor: (ctx) => areaGradient(ctx, "rgba(14, 165, 164, 0.24)", "rgba(14, 165, 164, 0.01)"),
              fill: true,
              tension: 0.32,
              borderWidth: 2.5,
              pointRadius: 0,
              pointHoverRadius: 5,
              pointHoverBackgroundColor: "#0ea5a4",
            },
            {
              label: "Nhiệt độ (°C)",
              data: rows.map((row) => numeric(row.temperature)),
              borderColor: "#f59e0b",
              tension: 0.32,
              borderWidth: 1.8,
              pointRadius: 0,
              pointHoverRadius: 4,
            },
            {
              label: "Độ ẩm (%)",
              data: rows.map((row) => numeric(row.humidity)),
              borderColor: "#2563eb",
              borderDash: [4, 3],
              tension: 0.32,
              borderWidth: 1.6,
              pointRadius: 0,
              pointHoverRadius: 4,
              yAxisID: "humidity",
            },
          ],
        },
        options,
      });
    }
    if (publicView) {
      $("history-rows").replaceChildren(...[...rows].reverse().slice(0, 6).map((reading) => {
        const level = warning(reading);
        const card = node("article", `history-reading ${level.level}`);
        card.setAttribute("role", "listitem");
        const time = node("time", "", timeText(reading.created_at));
        time.dateTime = reading.created_at;
        card.append(time, node("strong", "", measure(reading.heat_index, " °C")),
          node("p", "", `${measure(reading.temperature, " °C")} · Độ ẩm ${measure(reading.humidity, "%")}`), badge(level.label, level.level));
        return card;
      }));
      return;
    }
    $("history-rows").replaceChildren(...[...rows].reverse().map((reading) => {
      const row = node("tr");
      row.append(node("td", "", timeText(reading.created_at)), node("td", "", measure(reading.temperature, " °C")), node("td", "", measure(reading.humidity, " %")), node("td", "", measure(reading.heat_index, " °C")));
      const status = node("td");
      const level = warning(reading);
      status.append(badge(level.label, level.level));
      row.append(status);
      return row;
    }));
  }
  function forecastHour(hour, isPeak = false) {
    const level = warning(hour);
    const item = node("div", `forecast-hour ${level.level}${isPeak ? " is-peak" : ""}`);
    const time = node("time", "", timeText(hour.time, true));
    time.dateTime = hour.time;
    item.append(time, node("strong", "", measure(hour.heat_index, " °C")), node("small", "", level.label));
    if (isPeak) item.append(node("span", "forecast-peak-tag", "Đỉnh điểm"));
    return item;
  }
  function forecastMessage(text, error = false) {
    if ($("forecast-content")) $("forecast-content").hidden = true;
    message("forecast-message", text, error);
    if (publicView && $("weather-hours")) {
      $("weather-hours").hidden = true;
      message("weather-forecast-message", text, error);
    }
  }
  function renderForecast(data) {
    const hours = Array.isArray(data.hourly) ? data.hourly : [];
    if (hours.length !== 5 || hours.some(hour => !parseTime(hour?.time) || numeric(hour?.heat_index) === null)) {
      throw new Error("Máy chủ chưa cung cấp đủ 5 giờ dự báo LSTM hợp lệ.");
    }
    const peak = Math.max(...hours.map((hour) => Number(hour.heat_index)));
    const peakIndex = hours.findIndex((hour) => Number(hour.heat_index) === peak);
    if (publicView && $("weather-hours")) {
      $("weather-hours").replaceChildren(...hours.map((hour, index) => forecastHour(hour, index === peakIndex)));
      $("weather-hours").hidden = false;
      message("weather-forecast-message", "");
    }
    if (!$("forecast-content")) return;
    $("forecast-content").hidden = false;
    message("forecast-message", window.Chart ? "" : "Không tải được thư viện biểu đồ; kết quả từng giờ vẫn hiển thị bên dưới.");
    const level = warning({ heat_index: peak, warning_level: data.warning_level, warning_status: data.warning_status });
    $("forecast-status").textContent = level.label;
    $("forecast-status").className = `badge-status ${level.level}`;
    $("forecast-generated").textContent = `Tạo lúc ${timeText(data.generated_at)}`;
    $("model-note").textContent = data.model_note || "Mô hình thử nghiệm phục vụ đồ án. Kết quả dự báo có thể khác điều kiện thực tế.";
    $("forecast-hours").replaceChildren(...hours.map((hour, index) => forecastHour(hour, index === peakIndex)));
    if (state.forecastChart) { state.forecastChart.destroy(); state.forecastChart = null; }
    if ($("forecast-chart")?.parentElement) $("forecast-chart").parentElement.hidden = !window.Chart;
    if (window.Chart) {
      const values = hours.map((hour) => numeric(hour.heat_index));
      const pointColors = values.map((v) => v >= 38 ? "#dc2626" : v >= 32 ? "#d97706" : "#0ea5a4");
      const options = chartOptions();
      options.plugins.legend.display = false;
      options.scales.y.suggestedMin = Math.floor(Math.min(...values, 28) - 1);
      options.scales.y.suggestedMax = Math.ceil(Math.max(...values, 34) + 1.5);
      state.forecastChart = new Chart($("forecast-chart"), {
        type: "line",
        data: {
          labels: hours.map((hour) => timeText(hour.time, true)),
          datasets: [{
            label: "Chỉ số nóng bức (°C)",
            data: values,
            borderColor: "#155eef",
            backgroundColor: (ctx) => areaGradient(ctx, "rgba(21, 94, 239, 0.22)", "rgba(14, 165, 164, 0.02)"),
            fill: true,
            borderWidth: 2.8,
            pointRadius: 5.5,
            pointHoverRadius: 7,
            pointBackgroundColor: "#ffffff",
            pointBorderColor: pointColors,
            pointBorderWidth: 2.8,
            tension: 0.34,
          }],
        },
        options,
        plugins: [heatThresholdsPlugin],
      });
    }
  }
  function alertKey(reading) {
    return `${reading?.id ?? ""}|${reading?.device_id ?? ""}|${reading?.created_at ?? ""}`;
  }
  function buildAlertItem(reading, isNew = false) {
    const level = warning(reading);
    const item = node("article", `alert-item ${level.level}${isNew ? " is-new" : ""}`);
    const detail = node("div", "alert-detail");
    const heading = node("strong", "", level.label);
    if (isNew) heading.append(node("span", "alert-new-tag", "MỚI"));
    const stationLabel = reading.device_name && reading.device_name !== reading.device_id
      ? `${reading.device_name} (${reading.device_id})`
      : reading.device_id;
    detail.append(heading, node("p", "", `${stationLabel} · Chỉ số nóng bức ${measure(reading.heat_index, " °C")} · Nhiệt độ ${measure(reading.temperature, " °C")} · Độ ẩm ${measure(reading.humidity, " %")}`));
    item.append(node("span", "alert-symbol", level.level === "danger" ? "⚠" : "△"), detail, node("time", "alert-time", timeText(reading.created_at)));
    return item;
  }
  function renderAlerts(readings, newKeys = new Set()) {
    state.alerts = Array.isArray(readings) ? readings.slice(0, 50) : [];
    message("alert-message", state.alerts.length ? `${state.alerts.length} bản đo cảnh báo gần nhất. Tự động cập nhật theo thời gian thực.` : "Không có bản đo vượt ngưỡng tại điểm đo này.");
    $("alert-list").replaceChildren(...state.alerts.map((reading) => buildAlertItem(reading, newKeys.has(alertKey(reading)))));
  }
  function setAlertLiveStatus(mode, text) {
    const pill = $("alert-live-status");
    if (!pill) return;
    pill.className = `alert-live-pill ${mode}`;
    const span = pill.querySelector("span");
    if (span) span.textContent = text;
  }
  function playAlertBeep(level) {
    if (!state.alertSound) return;
    try {
      const AudioCtx = window.AudioContext || window.webkitAudioContext;
      if (!AudioCtx) return;
      const ctx = new AudioCtx();
      const now = ctx.currentTime;
      const freqs = level === "danger" ? [880, 1175, 880] : [740, 932];
      freqs.forEach((freq, idx) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = "sine";
        osc.frequency.setValueAtTime(freq, now + idx * 0.14);
        gain.gain.setValueAtTime(0.08, now + idx * 0.14);
        gain.gain.exponentialRampToValueAtTime(0.0001, now + idx * 0.14 + 0.12);
        osc.connect(gain);
        gain.connect(ctx.destination);
        osc.start(now + idx * 0.14);
        osc.stop(now + idx * 0.14 + 0.13);
      });
      setTimeout(() => { ctx.close?.().catch(() => {}); }, 700);
    } catch (_) { /* ignore audio errors */ }
  }
  function showRealtimeAlertBanner(reading) {
    const banner = $("realtime-alert-banner");
    if (!banner) return;
    const level = warning(reading);
    banner.className = `realtime-alert-banner ${level.level}`;
    const badgeEl = $("realtime-alert-badge");
    if (badgeEl) {
      badgeEl.textContent = level.label;
      badgeEl.className = `badge-status ${level.level}`;
    }
    const stationLabel = reading.device_name && reading.device_name !== reading.device_id
      ? `${reading.device_name} (${reading.device_id})`
      : reading.device_id;
    $("realtime-alert-title").textContent = `${stationLabel} · Heat Index ${measure(reading.heat_index, " °C")}`;
    $("realtime-alert-body").textContent = `Nhiệt độ ${measure(reading.temperature, " °C")} · Độ ẩm ${measure(reading.humidity, "%")}. Vừa nhận trực tiếp từ ESP32.`;
    $("realtime-alert-time").textContent = timeText(reading.created_at);
    banner.dataset.deviceId = reading.device_id || "";
    banner.hidden = false;
    clearTimeout(state.alertBannerTimer);
    state.alertBannerTimer = setTimeout(() => { banner.hidden = true; }, 10000);
  }
  function handleRealtimeAlert(reading) {
    if (!reading || numeric(reading.heat_index) === null) return;
    const key = alertKey(reading);
    if (!state.selectedId || reading.device_id === state.selectedId) {
      const merged = [reading, ...state.alerts.filter((item) => alertKey(item) !== key)].slice(0, 50);
      renderAlerts(merged, new Set([key]));
    }
    const navBadge = $("nav-alert-count");
    if (navBadge) {
      if (publicView && navBadge.hidden) {
        navBadge.textContent = "1";
        navBadge.hidden = false;
      }
      navBadge.classList.remove("pulse");
      void navBadge.offsetWidth;
      navBadge.classList.add("pulse");
    }
    showRealtimeAlertBanner(reading);
    playAlertBeep(warning(reading).level);
    if (state.alertNotify && "Notification" in window && Notification.permission === "granted") {
      try {
        const level = warning(reading);
        new Notification(`HeatWatch · ${level.label}`, {
          body: `${reading.device_name || reading.device_id}: Heat Index ${measure(reading.heat_index, " °C")} (${measure(reading.temperature, " °C")}, ${measure(reading.humidity, "%")})`,
        });
      } catch (_) { /* ignore notification errors */ }
    }
    void refresh();
  }
  function connectAlertStream() {
    if (typeof window.EventSource !== "function") {
      setAlertLiveStatus("error", "Trình duyệt không hỗ trợ SSE · Tự làm mới mỗi 15 giây");
      return;
    }
    if (state.alertSource) { state.alertSource.close(); state.alertSource = null; }
    setAlertLiveStatus("connecting", "Đang kết nối cảnh báo trực tiếp…");
    const source = new EventSource("/api/alerts/stream");
    state.alertSource = source;
    source.addEventListener("connected", () => {
      setAlertLiveStatus("live", "Đang theo dõi trực tiếp");
    });
    source.onopen = () => {
      setAlertLiveStatus("live", "Đang theo dõi trực tiếp");
    };
    source.addEventListener("alert", (event) => {
      try {
        const reading = JSON.parse(event.data);
        handleRealtimeAlert(reading);
      } catch (_) { /* ignore malformed event */ }
    });
    source.onerror = () => {
      setAlertLiveStatus("connecting", "Mất kết nối trực tiếp · Đang tự động nối lại…");
    };
  }

  async function loadDetails(id, generation) {
    if (!id) {
      renderHistory([]); renderAlerts([]);
      message("history-message", publicView ? "Chưa có điểm đo để xem lịch sử." : "Đăng ký hoặc chọn điểm đo để xem lịch sử.");
      forecastMessage(publicView ? "Chưa có điểm đo để xem dự báo." : "Đăng ký hoặc chọn điểm đo để xem dự báo.");
      message("alert-message", publicView ? "Chưa có điểm đo để xem cảnh báo." : "Đăng ký hoặc chọn điểm đo để xem cảnh báo.");
      return;
    }
    const params = new URLSearchParams({ device_id: id, limit: state.filters.limit });
    if (publicView) {
      if (state.filters.date) {
        params.set("start", `${state.filters.date}T00:00:00+07:00`);
        params.set("end", `${state.filters.date}T23:59:59+07:00`);
      } else {
        const hours = Number(state.filters.hours) || 3;
        const device = state.devices.find((entry) => entry.device_id === id);
        const anchor = parseTime(device?.latest?.created_at) || new Date();
        const startTime = new Date(anchor.getTime() - hours * 3600 * 1000);
        params.set("start", startTime.toISOString());
        params.set("end", anchor.toISOString());
      }
    } else {
      if (state.filters.start) params.set("start", state.filters.start);
      if (state.filters.end) params.set("end", state.filters.end);
    }
    const results = await Promise.allSettled([
      api(`/api/sensor/history?${params}`),
      api(`/api/sensor/forecast?${new URLSearchParams({ device_id: id })}`),
      api(`/api/alerts?${new URLSearchParams({ device_id: id, limit: "50" })}`),
    ]);
    if (generation !== state.generation || id !== state.selectedId) return;
    if (results[0].status === "fulfilled") renderHistory(Array.isArray(results[0].value) ? results[0].value : []);
    else {
      renderHistory([]);
      message("history-message", `Không tải được lịch sử: ${results[0].reason.message}`, true);
    }
    if (results[1].status === "fulfilled") {
      try { renderForecast(results[1].value); }
      catch (error) { forecastMessage(error.message, true); }
    } else {
      const error = results[1].reason;
      const friendlyForecast = publicView && ["insufficient_data", "stale_data"].includes(error.code)
        ? "Hệ thống đang thu thập thêm dữ liệu (cần đủ 12 giờ liên tục) để dự báo 5 giờ tới."
        : `Chưa có dự báo · ${error.message}`;
      forecastMessage(friendlyForecast, !["insufficient_data", "model_unavailable", "stale_data"].includes(error.code));
    }
    if (results[2].status === "fulfilled") renderAlerts(Array.isArray(results[2].value) ? results[2].value : []);
    else { $("alert-list").replaceChildren(); message("alert-message", `Không tải được cảnh báo: ${results[2].reason.message}`, true); }
  }

  async function refresh() {
    if (state.busy) { state.queued = true; return; }
    state.busy = true;
    $("refresh-button").disabled = true;
    const generation = ++state.generation;
    try {
      const devices = await api("/api/devices");
      if (!Array.isArray(devices)) throw new Error("Danh sách thiết bị không hợp lệ.");
      state.devices = devices;
      if (!devices.some((device) => device.device_id === state.selectedId && (!publicView || device.enabled))) state.selectedId = devices.find((device) => device.enabled)?.device_id || (publicView ? "" : devices[0]?.device_id) || "";
      renderDevices();
      renderReading(devices.find((device) => device.device_id === state.selectedId));
      renderMap();
      $("global-error").hidden = true;
      $("connection-status").textContent = publicView ? "Đang hoạt động" : "Đã kết nối máy chủ";
      $("connection-dot").className = "status-dot";
      const now = new Date();
      $("sync-time").textContent = clockFormat.format(now);
      $("sync-date").textContent = `${dateFormat.format(now)} · Giờ Việt Nam`;
      await loadDetails(state.selectedId, generation);
    } catch (error) {
      $("global-error").textContent = `Không kết nối được dữ liệu máy chủ: ${error.message} Chọn “Làm mới” để thử lại. Các dữ liệu đang hiển thị (nếu có) thuộc lần đồng bộ trước.`;
      $("global-error").hidden = false;
      $("connection-status").textContent = "Mất kết nối máy chủ";
      $("connection-dot").className = "status-dot error";
      if (!state.devices.length && $("device-rows")) emptyRow("device-rows", 6, "Không tải được danh sách thiết bị. Hãy kiểm tra Flask và MySQL rồi chọn Làm mới.");
    } finally {
      state.busy = false;
      $("refresh-button").disabled = false;
      if (state.queued) { state.queued = false; void refresh(); }
    }
  }
  async function selectDevice(id, focus) {
    state.selectedId = id;
    $("device-select").value = id;
    if ($("history-device-select")) $("history-device-select").value = id;
    const generation = ++state.generation;
    const device = state.devices.find((entry) => entry.device_id === id);
    renderReading(device);
    renderStationList();
    renderHistory([]);
    $("alert-list").replaceChildren();
    message("history-message", "Đang tải lịch sử…");
    forecastMessage("Đang tải dự báo LSTM…");
    message("alert-message", "Đang tải cảnh báo…");
    if (focus) {
      $(publicView ? "public-current" : "overview").scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth" });
      const position = trustedPosition(device);
      if (state.map && position) state.map.setView([position.latitude, position.longitude], 13);
    }
    await loadDetails(id, generation);
  }

  function setPublicTab(tab, updateHash = true) {
    if (!publicView) return;
    const allowed = ["weather", "points", "overview", "alerts"];
    const target = allowed.includes(tab) ? tab : "weather";
    document.body?.setAttribute?.("data-active-tab", target);
    document.querySelectorAll(".public-header .nav-item").forEach((item) => {
      const itemTab = item.dataset?.tabTarget || item.getAttribute?.("href")?.replace(/^#/, "");
      item.classList?.toggle("active", itemTab === target);
    });
    if (updateHash && window.history?.replaceState) {
      window.history.replaceState(null, "", `#${target}`);
    }
    if (target === "overview") {
      setTimeout(() => {
        state.map?.invalidateSize();
        if (!state.hasFittedLocations) fitMap();
      }, 60);
    } else if (target === "points") {
      setTimeout(() => {
        state.historyChart?.resize();
        state.forecastChart?.resize();
      }, 60);
    }
    window.scrollTo?.({ top: 0, behavior: "instant" });
  }

  function showStationDetails() {
    if (publicView) {
      setPublicTab("points", true);
      return;
    }
    $("station-detail")?.scrollIntoView({ behavior: "smooth", block: "start" });
  }

  function openDeviceDialog(device = null) {
    state.editingId = device?.device_id || null;
    $("device-dialog-title").textContent = device ? "Cập nhật thiết bị" : "Thêm thiết bị";
    $("device-form").reset();
    $("form-device-id").value = device?.device_id || "";
    $("form-device-id").readOnly = Boolean(device);
    $("form-device-name").value = device?.name || "";
    const position = trustedPosition(device);
    $("form-latitude").value = position?.latitude ?? "";
    $("form-longitude").value = position?.longitude ?? "";
    $("form-latitude").required = !device;
    $("form-longitude").required = !device;
    $("form-enabled").checked = device ? Boolean(device.enabled) : true;
    $("form-error").hidden = true;
    $("device-dialog").showModal();
  }
  async function saveDevice(event) {
    event.preventDefault();
    if (!$("device-form").reportValidity()) return;
    $("save-device").disabled = true;
    $("form-error").hidden = true;
    const data = { device_id: $("form-device-id").value.trim(), name: $("form-device-name").value.trim(), enabled: $("form-enabled").checked };
    const latitude = $("form-latitude").value.trim(), longitude = $("form-longitude").value.trim();
    if (latitude || longitude) {
      if (!latitude || !longitude) {
        $("form-error").textContent = "Cần nhập cả vĩ độ và kinh độ, hoặc để trống cả hai khi chỉ sửa tên thiết bị.";
        $("form-error").hidden = false;
        $("save-device").disabled = false;
        return;
      }
      data.latitude = Number(latitude);
      data.longitude = Number(longitude);
    }
    try {
      await api(state.editingId ? `/api/devices/${encodeURIComponent(state.editingId)}` : "/api/devices", { method: state.editingId ? "PUT" : "POST", body: JSON.stringify(data) });
      $("device-dialog").close();
      toast(state.editingId ? "Đã cập nhật thiết bị." : "Đã thêm thiết bị. Chờ trạm gửi bản đo đầu tiên.");
      if (!state.selectedId) state.selectedId = data.device_id;
      await refresh();
    } catch (error) {
      $("form-error").textContent = error.message;
      $("form-error").hidden = false;
    } finally { $("save-device").disabled = false; }
  }
  async function disableDevice(device, button) {
    if (!window.confirm(`Tắt điểm đo “${device.name || device.device_id}”? Lịch sử đo được giữ lại. Bạn có thể bật lại trong phần Sửa.`)) return;
    button.disabled = true;
    try {
      await api(`/api/devices/${encodeURIComponent(device.device_id)}`, { method: "DELETE" });
      toast("Đã tắt thiết bị và giữ lại lịch sử.");
      await refresh();
    } catch (error) { toast(`Không tắt được thiết bị: ${error.message}`); }
    finally { button.disabled = false; }
  }
  async function applyHistory(event) {
    event.preventDefault();
    const start = $("history-start").value, end = $("history-end").value;
    if (start && end && start > end) { toast("Thời gian bắt đầu cần trước thời gian kết thúc."); return; }
    state.filters = { limit: $("history-limit").value, start: start ? `${start}:00+07:00` : "", end: end ? `${end}:59+07:00` : "" };
    await selectDevice(state.selectedId, false);
  }
  function exportHistory() {
    if (!state.history.length) return;
    const safeCell = (value) => {
      let text = String(value ?? "");
      if (/^[=+@\-\t\r]/.test(text)) text = `'${text}`;
      return `"${text.replaceAll('"', '""')}"`;
    };
    const records = [["Mã thiết bị", "Thời gian (UTC+7)", "Nhiệt độ (°C)", "Độ ẩm (%)", "Chỉ số nóng bức (°C)", "Cảnh báo"], ...state.history.map((reading) => [reading.device_id, timeText(reading.created_at), reading.temperature, reading.humidity, reading.heat_index, warning(reading).label])];
    const blob = new Blob(["\uFEFF", records.map((record) => record.map(safeCell).join(",")).join("\r\n")], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const anchor = node("a");
    anchor.href = url;
    anchor.download = `heatwatch-${state.selectedId.replace(/[^a-zA-Z0-9_.-]/g, "_")}-history.csv`;
    anchor.click();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  }

  $("theme-toggle")?.addEventListener("click", () => {
    document.body?.classList?.toggle("theme-dark");
    if (state.history.length) renderHistory(state.history);
  });
  $("station-search").addEventListener("input", (event) => { state.search = event.target.value; renderStationList(); });
  if (publicView) {
    $("open-station-detail")?.addEventListener("click", (event) => { event.preventDefault(); showStationDetails(); });
    $("station-detail")?.addEventListener("toggle", () => {
      if ($("station-detail").open) { state.historyChart?.resize(); state.forecastChart?.resize(); }
    });
  }
  $("refresh-button").addEventListener("click", () => {
    if (publicView) window.HeatWatchWeather?.refresh();
    void refresh();
  });
  $("device-select").addEventListener("change", (event) => { void selectDevice(event.target.value, true); });
  $("history-device-select")?.addEventListener("change", (event) => { void selectDevice(event.target.value, false); });
  $("fit-map").addEventListener("click", fitMap);
  $("toggle-thermal-layer")?.addEventListener("click", (event) => {
    state.showThermal = !state.showThermal;
    const btn = event.currentTarget;
    btn.classList.toggle("active", state.showThermal);
    btn.setAttribute("aria-pressed", String(state.showThermal));
    renderMap();
  });
  $("add-device")?.addEventListener("click", () => openDeviceDialog());
  $("close-dialog")?.addEventListener("click", () => $("device-dialog").close());
  $("cancel-dialog")?.addEventListener("click", () => $("device-dialog").close());
  $("device-form")?.addEventListener("submit", saveDevice);
  $("history-filter")?.addEventListener("submit", applyHistory);
  $("clear-history")?.addEventListener("click", () => { $("history-filter")?.reset(); state.filters = { limit: "100", start: "", end: "" }; void selectDevice(state.selectedId, false); });
  $("export-history")?.addEventListener("click", exportHistory);
  document.querySelectorAll("[data-history-hours]").forEach((btn) => btn.addEventListener("click", () => {
    const nextHours = Number(btn.dataset.historyHours) || 3;
    const hadDate = Boolean(state.filters.date);
    if (!hadDate && state.filters.hours === nextHours) return;
    state.filters.hours = nextHours;
    state.filters.date = "";
    if ($("history-date")) {
      $("history-date").value = "";
      $("history-date").closest(".history-date-picker")?.classList.remove("active");
    }
    document.querySelectorAll("[data-history-hours]").forEach((el) => el.classList.toggle("active", el === btn));
    if (state.selectedId) void selectDevice(state.selectedId, false);
  }));
  $("history-date")?.addEventListener("change", (event) => {
    const picked = event.target.value || "";
    state.filters.date = picked;
    event.target.closest(".history-date-picker")?.classList.toggle("active", Boolean(picked));
    document.querySelectorAll("[data-history-hours]").forEach((el) => {
      el.classList.toggle("active", !picked && Number(el.dataset.historyHours) === state.filters.hours);
    });
    if (state.selectedId) void selectDevice(state.selectedId, false);
  });
  document.querySelectorAll(".nav-item, [data-tab-target]").forEach((link) => link.addEventListener("click", (event) => {
    if (publicView) {
      const target = link.dataset?.tabTarget || link.getAttribute?.("href")?.replace(/^#/, "");
      if (["weather", "points", "overview", "alerts"].includes(target)) {
        event.preventDefault();
        setPublicTab(target, true);
        return;
      }
    }
    document.querySelectorAll(".nav-item").forEach((item) => item.classList.remove("active"));
    link.classList.add("active");
  }));
  if (publicView) {
    const today = todayIsoDate();
    state.filters.date = today;
    if ($("history-date")) {
      $("history-date").value = today;
      $("history-date").closest(".history-date-picker")?.classList.add("active");
    }
    document.querySelectorAll("[data-history-hours]").forEach((el) => el.classList.remove("active"));
    const initialTab = (window.location?.hash || "").replace(/^#/, "");
    setPublicTab(["weather", "points", "overview", "alerts"].includes(initialTab) ? initialTab : "weather", false);
    window.addEventListener?.("hashchange", () => {
      const nextTab = (window.location?.hash || "").replace(/^#/, "");
      if (["weather", "points", "overview", "alerts"].includes(nextTab)) setPublicTab(nextTab, false);
    });
  }
  $("alert-sound-toggle")?.addEventListener("click", (event) => {
    state.alertSound = !state.alertSound;
    const btn = event.currentTarget;
    btn.setAttribute("aria-pressed", String(state.alertSound));
    btn.textContent = state.alertSound ? "🔊 Âm thanh: Bật" : "🔇 Âm thanh";
    if (state.alertSound) playAlertBeep("caution");
  });
  $("alert-notify-toggle")?.addEventListener("click", async (event) => {
    const btn = event.currentTarget;
    if (!("Notification" in window)) {
      toast("Trình duyệt không hỗ trợ thông báo hệ thống.");
      return;
    }
    if (state.alertNotify) {
      state.alertNotify = false;
      btn.setAttribute("aria-pressed", "false");
      btn.textContent = "🔔 Thông báo";
      return;
    }
    const perm = Notification.permission === "granted" ? "granted" : await Notification.requestPermission();
    state.alertNotify = perm === "granted";
    btn.setAttribute("aria-pressed", String(state.alertNotify));
    btn.textContent = state.alertNotify ? "🔔 Thông báo: Bật" : "🔔 Thông báo";
    toast(state.alertNotify ? "Đã bật thông báo trình duyệt cho cảnh báo nóng bức." : "Chưa được cấp quyền thông báo trình duyệt.");
  });
  $("realtime-alert-close")?.addEventListener("click", () => {
    $("realtime-alert-banner").hidden = true;
    clearTimeout(state.alertBannerTimer);
  });
  $("realtime-alert-open")?.addEventListener("click", () => {
    const targetId = $("realtime-alert-banner")?.dataset?.deviceId;
    $("realtime-alert-banner").hidden = true;
    if (targetId && targetId !== state.selectedId) void selectDevice(targetId, false);
    if (publicView) setPublicTab("alerts", true);
    else $("alerts")?.scrollIntoView({ behavior: "smooth", block: "start" });
  });
  async function loadModelMetrics() {
    const panel = $("model-metrics-panel");
    if (!panel) return;
    try {
      const data = await api("/api/model/metrics");
      if (!data?.available || !data?.metrics?.overall) {
        message("metric-message", data?.message || "Chưa có báo cáo đánh giá mô hình.");
        if ($("metric-source-badge")) $("metric-source-badge").textContent = "Chưa có báo cáo";
        if ($("metric-body")) $("metric-body").hidden = true;
        return;
      }
      const overall = data.metrics.overall;
      $("metric-mae").textContent = `${Number(overall.mae).toFixed(4)} °C`;
      $("metric-rmse").textContent = `${Number(overall.rmse).toFixed(4)} °C`;
      $("metric-r2").textContent = Number(overall.r2).toFixed(4);
      const srcLabel = data.source === "mysql" ? "Dữ liệu thực MySQL" : data.source === "csv" ? "Dữ liệu CSV" : "Dữ liệu mẫu kiểm thử";
      if ($("metric-source-badge")) {
        $("metric-source-badge").textContent = srcLabel;
        $("metric-source-badge").className = `badge-status ${data.source === "mysql" ? "normal" : "caution"}`;
      }
      $("metric-meta").textContent = `Huấn luyện lúc ${timeText(data.trained_at)} · ${data.train_samples} mẫu train / ${data.test_samples} mẫu test (${data.total_valid_hours} giờ hợp lệ).`;
      const rows = (data.metrics.per_horizon || []).map((item) => {
        const tr = node("tr");
        tr.append(
          node("td", "", `+${item.horizon_hour} giờ`),
          node("td", "", Number(item.mae).toFixed(4)),
          node("td", "", Number(item.rmse).toFixed(4)),
          node("td", "", Number(item.r2).toFixed(4)),
        );
        return tr;
      });
      $("metric-horizon-rows").replaceChildren(...rows);
      message("metric-message", "");
      $("metric-body").hidden = false;
    } catch (error) {
      message("metric-message", `Không tải được chỉ số đánh giá: ${error.message}`, true);
    }
  }
  initMap();
  window.addEventListener("resize", () => state.map?.invalidateSize());
  void refresh();
  void loadModelMetrics();
  connectAlertStream();
  window.addEventListener("beforeunload", () => { state.alertSource?.close(); });
  setInterval(() => { if (!document.hidden && !$("device-dialog")?.open) void refresh(); }, 15000);
  document.addEventListener("visibilitychange", () => { if (!document.hidden && !$("device-dialog")?.open) void refresh(); });
})();
