"use strict";

window.HeatWatchWeather = (() => {
  const $ = (id) => document.getElementById(id);
  const city = { latitude: 10.78, longitude: 106.70, label: "TP. Hồ Chí Minh" };
  const symbols = {
    clear: "☀️", night: "🌙", "partly-cloudy": "🌤️", "partly-cloudy-night": "☁️",
    cloudy: "☁️", fog: "🌫️", rain: "🌧️", storm: "⛈️", snow: "❄️", unknown: "—",
  };
  let station = city, currentDevice = null, user = null, activeKey, lastAttempt = 0, pending, success, lastData = null;
  const timeLabel = (value) => value?.slice(11, 16) || "—";
  const decimal = new Intl.NumberFormat("vi-VN", { maximumFractionDigits: 1 });
  const numeric = (value) => {
    const n = typeof value === "number" ? value : Number(value);
    return value !== null && value !== undefined && value !== "" && Number.isFinite(n) ? n : null;
  };
  const measure = (value, unit) => {
    const n = numeric(value);
    return n !== null ? decimal.format(n) + unit : "—";
  };

  function render(data) {
    lastData = data;
    const current = data?.current || null;
    const espReading = !user ? currentDevice?.latest || null : null;
    const labelEl = $("weather-now-label");

    if (espReading) {
      if (labelEl) labelEl.textContent = "HIỆN TẠI";
      $("weather-temperature").textContent = measure(espReading.temperature, " °C");
      $("weather-humidity").textContent = measure(espReading.humidity, "%");
      $("weather-icon").textContent = current ? (symbols[current.icon] || symbols.unknown) : "🌡️";
      $("weather-description").textContent = current?.description || "Đo trực tiếp tại trạm";
      $("weather-rain-label").textContent = current?.rain_until
        ? `Khả năng mưa đến ${timeLabel(current.rain_until)}`
        : "Khả năng mưa";
      $("weather-rain").textContent = current ? measure(current.rain_probability, "%") : "—";
      $("weather-time").textContent = `Cập nhật lúc ${timeLabel(espReading.created_at)}`;
      $("weather-current").hidden = false;
      $("weather-status").hidden = true;
      return;
    }

    if (!current) return;
    if (labelEl) labelEl.textContent = user ? "VỊ TRÍ CỦA BẠN" : "HIỆN TẠI";
    $("weather-temperature").textContent = measure(current.temperature, " °C");
    $("weather-icon").textContent = symbols[current.icon] || symbols.unknown;
    $("weather-description").textContent = current.description;
    $("weather-humidity").textContent = measure(current.humidity, "%");
    $("weather-rain-label").textContent = current.rain_until ? "Khả năng mưa đến " + timeLabel(current.rain_until) : "Khả năng mưa";
    $("weather-rain").textContent = measure(current.rain_probability, "%");
    $("weather-time").textContent = "Cập nhật lúc " + timeLabel(current.time);
    $("weather-current").hidden = false;
    $("weather-status").hidden = true;
  }

  async function load(force = false) {
    const point = user || station;
    const key = point.latitude.toFixed(2) + "," + point.longitude.toFixed(2);
    $("weather-location").textContent = point.label;
    if (!user && currentDevice?.latest) {
      render(lastData);
    }
    const same = activeKey === key;
    if (same && (pending || (!force && Date.now() - lastAttempt < (success ? 600000 : 60000)))) return;
    const hadData = (same && !$("weather-current").hidden) || (!user && Boolean(currentDevice?.latest));
    pending?.abort();
    const controller = new AbortController();
    pending = controller;
    activeKey = key;
    lastAttempt = Date.now();
    $("weather-current").hidden = !hadData;
    $("weather-status").hidden = hadData;
    $("weather-status").textContent = "Đang tải thời tiết · " + point.label;
    $("weather-retry").hidden = true;
    const timeout = setTimeout(() => controller.abort(), 14000);
    let failureMessage = "Chưa tải được thông tin thời tiết.";
    try {
      const response = await fetch("/api/weather?" + new URLSearchParams({ point: key, current_only: "1" }), { signal: controller.signal });
      const data = await response.json().catch(() => null);
      if (pending !== controller) return;
      if (!response.ok || !data?.current) {
        if (typeof data?.error === "string" && data.error) failureMessage = data.error;
        throw new Error();
      }
      render(data);
      success = true;
    } catch {
      if (pending !== controller) return;
      success = false;
      $("weather-status").hidden = false;
      $("weather-status").textContent = failureMessage + (hadData ? " Đang hiển thị số đo gần nhất." : "");
      $("weather-retry").hidden = false;
    } finally {
      clearTimeout(timeout);
      if (pending === controller) pending = null;
    }
  }

  $("weather-use-location").addEventListener("click", async () => {
    const service = window.HeatWatchLocation;
    const button = $("weather-use-location");
    const help = $("weather-location-help");
    button.disabled = true;
    try {
      const position = service?.getPosition() || await service?.requestPosition({ focusMap: false });
      if (!position) {
        help.textContent = "Chưa lấy được vị trí của bạn. Hãy cho phép quyền vị trí rồi thử lại.";
        help.hidden = false;
        return;
      }
      user = { ...position, label: "Khu vực của bạn" };
      help.hidden = true;
      button.hidden = true;
      $("weather-use-station").hidden = false;
      void load(true);
    } finally {
      button.disabled = false;
    }
  });
  $("weather-use-station").addEventListener("click", () => {
    user = null;
    $("weather-use-station").hidden = true;
    $("weather-use-location").hidden = false;
    $("weather-location-help").hidden = true;
    void load(true);
  });
  $("weather-retry").addEventListener("click", () => void load(true));
  // Give the station request the first chance to choose a location. The city
  // is still available when the station API is slow or offline.
  setTimeout(() => { if (!activeKey) void load(); }, 800);
  return {
    setStation(device, position) {
      currentDevice = device || null;
      station = position
        ? { ...position, label: device.name || device.device_id }
        : (device ? { ...city, label: device.name || device.device_id } : city);
      if (!user && currentDevice?.latest) {
        $("weather-location").textContent = station.label;
        render(lastData);
      }
      void load();
    },
    refresh: () => void load(true),
  };
})();
