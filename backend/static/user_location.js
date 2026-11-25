/* One-shot, opt-in geolocation. Only a session invitation flag is stored;
   coordinates remain in memory, with no reverse geocoding or HTTP calls. */
"use strict";
window.HeatWatchLocation = (() => {
  let initialized = false, current = null, pending = null;
  let map = null, layers = null, onLocate = () => {}, mapButton = null;
  const $ = (id) => document.getElementById(id);
  function closeInvitation() {
    const dialog = $("location-invitation");
    dialog.close();
    dialog.hidden = true;
    try { sessionStorage.setItem("heatwatch.location.invited", "1"); } catch (_) {}
  }
  function message(text, kind = "") {
    $("user-location-status").textContent = text;
    $("user-location-status").className = `user-location-status ${kind}`;
    if (!$("location-invitation").hidden) {
      $("location-invite-message").textContent = text;
      $("location-invitation").classList.toggle("error", kind === "error");
    }
  }
  function busy(value) {
    $("enable-user-location").disabled = value;
    if (mapButton) {
      mapButton.disabled = value;
      mapButton.setAttribute("aria-busy", String(value));
    }
  }
  function getPosition() { return current ? { ...current } : null; }
  function requestPosition({ focusMap = true } = {}) {
    if (pending) return pending.promise;
    if (!map) { message("Chưa tải được bản đồ. Bạn vẫn có thể nhập điểm đi thủ công.", "error"); return Promise.resolve(null); }
    if (window.isSecureContext === false) {
      message("Trình duyệt cần HTTPS hoặc localhost để định vị. Bạn vẫn xem bản đồ và nhập điểm đi thủ công được.", "error");
      return Promise.resolve(null);
    }
    if (!navigator.geolocation?.getCurrentPosition) {
      message("Trình duyệt chưa hỗ trợ định vị. Bạn vẫn xem bản đồ và nhập điểm đi thủ công được.", "error");
      return Promise.resolve(null);
    }
    let resolve;
    const attempt = { promise: new Promise(done => { resolve = done; }), timer: null };
    pending = attempt;
    busy(true);
    message("Đang lấy vị trí. Nếu trình duyệt hỏi, hãy chọn cho phép; bạn vẫn có thể chọn Để sau.");
    function finish(value) {
      clearTimeout(attempt.timer);
      if (pending === attempt) pending = null;
      busy(false);
      resolve(value);
    }
    attempt.cancel = () => { if (pending === attempt) finish(null); };
    function fail(error) {
      if (pending !== attempt) return;
      const errors = {
        1: "Bạn chưa cho phép định vị. Kiểm tra quyền vị trí của trang trong trình duyệt và quyền vị trí của trình duyệt trong cài đặt thiết bị, rồi bấm Định vị tôi. Bạn vẫn có thể nhập điểm đi thủ công.",
        2: "Thiết bị chưa xác định được vị trí. Kiểm tra quyền vị trí và bật dịch vụ Vị trí trong cài đặt thiết bị, rồi bấm Định vị tôi. Bạn vẫn có thể nhập điểm đi thủ công.",
        3: "Lấy vị trí quá lâu. Kiểm tra quyền và cài đặt Vị trí của thiết bị, rồi bấm Định vị tôi hoặc nhập điểm đi thủ công.",
      };
      message((errors[error?.code] || "Không lấy được vị trí. Bạn vẫn xem bản đồ và nhập điểm đi thủ công được.") + (current ? " Chấm xanh vẫn là vị trí ở lần định vị trước." : ""), "error");
      finish(null);
    }
    // Also bound the wait for a browser permission prompt left unanswered.
    attempt.timer = setTimeout(() => fail({ code: 3 }), 22000);
    try {
      navigator.geolocation.getCurrentPosition((position) => {
        if (pending !== attempt) return; // Ignore a late result after Để sau/timeout.
        const { latitude, longitude, accuracy } = position.coords || {};
        if (![latitude, longitude, accuracy].every(value => typeof value === "number" && Number.isFinite(value)) || Math.abs(latitude) > 90 || Math.abs(longitude) > 180 || accuracy < 0) {
          fail({ code: 2 }); return;
        }
        current = { latitude, longitude, accuracy, timestamp: Number.isFinite(position.timestamp) ? position.timestamp : Date.now() };
        const point = [latitude, longitude];
        const radius = accuracy;
        layers.clearLayers();
        const circle = L.circle(point, { radius, color: "#3b8ade", weight: 1, fillColor: "#4195ee", fillOpacity: .12, pane: "userLocationAccuracy", className: "user-location-accuracy", interactive: false }).addTo(layers);
        const marker = L.circleMarker(point, { radius: 8, color: "white", weight: 3, fillColor: "#2f80ed", fillOpacity: 1, pane: "userLocationDot", className: "user-location-dot" }).addTo(layers);
        const popup = document.createElement("div");
        popup.className = "user-location-popup";
        const title = document.createElement("strong"); title.textContent = "Vị trí của bạn";
        const detail = document.createElement("div"); detail.textContent = `Độ chính xác khoảng ${Math.round(accuracy)} m · ${new Intl.DateTimeFormat("vi-VN", { timeZone: "Asia/Ho_Chi_Minh", hour: "2-digit", minute: "2-digit", hour12: false }).format(new Date(current.timestamp))}`;
        popup.append(title, detail);
        marker.bindTooltip("Vị trí của bạn", { permanent: true, direction: "top", offset: [0, -10], className: "user-location-tooltip" }).bindPopup(popup);
        onLocate(getPosition()); // Prevent the first station poll from overriding this view.
        if (radius > 0) map.fitBounds(circle.getBounds(), { padding: [40, 40], maxZoom: 16, animate: false });
        else map.setView(point, 16, { animate: false });
        closeInvitation();
        message(`Vị trí của bạn · Độ chính xác khoảng ${Math.round(accuracy)} m.`, "located");
        if (focusMap) $("station-map").scrollIntoView({ behavior: window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "instant" : "smooth", block: "center" });
        finish(getPosition());
      }, fail, { enableHighAccuracy: true, timeout: 15000, maximumAge: 0 });
    } catch (_) { fail({ code: 2 }); }
    return attempt.promise;
  }
  function init(targetMap, locatedCallback = () => {}) {
    if (initialized || !$("location-invitation")) return;
    initialized = true;
    map = targetMap;
    onLocate = locatedCallback;
    const invitation = $("location-invitation");
    let invited = false;
    try { invited = sessionStorage.getItem("heatwatch.location.invited") === "1"; } catch (_) {}
    if (!invited) { invitation.hidden = false; invitation.showModal(); }
    $("enable-user-location").addEventListener("click", () => { void requestPosition(); });
    function defer() {
      pending?.cancel();
      closeInvitation();
      message("Bạn vẫn có thể xem bản đồ và nhập điểm đi thủ công. Bấm Định vị tôi khi cần.");
    }
    $("defer-user-location").addEventListener("click", defer);
    invitation.addEventListener("cancel", (event) => { event.preventDefault(); defer(); });
    if (!map) return;
    layers = L.layerGroup().addTo(map);
    map.createPane("userLocationAccuracy").style.zIndex = "410";
    map.createPane("userLocationDot").style.zIndex = "640";
    const control = L.control({ position: "topright" });
    control.onAdd = () => {
      const container = document.createElement("div"); container.className = "leaflet-bar location-map-control";
      mapButton = document.createElement("button"); mapButton.type = "button"; mapButton.id = "locate-me";
      const icon = document.createElement("span"); icon.textContent = "◎"; icon.setAttribute("aria-hidden", "true");
      mapButton.append(icon, document.createTextNode("Định vị tôi"));
      mapButton.addEventListener("click", () => { void requestPosition(); });
      container.append(mapButton);
      L.DomEvent.disableClickPropagation(container);
      L.DomEvent.disableScrollPropagation(container);
      return container;
    };
    control.addTo(map);
  }
  return { init, getPosition, requestPosition };
})();
