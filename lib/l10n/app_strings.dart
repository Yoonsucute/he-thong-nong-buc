import 'package:flutter/material.dart';

import '../models/rain_route.dart';
import '../models/sensor.dart';
import '../services/user_location_service.dart';

enum AppLanguage { vi, en }

class AppSettingsController extends ChangeNotifier {
  AppSettingsController({
    ThemeMode themeMode = ThemeMode.system,
    AppLanguage language = AppLanguage.vi,
  }) : _themeMode = themeMode,
       _language = language;

  ThemeMode _themeMode;
  AppLanguage _language;

  ThemeMode get themeMode => _themeMode;
  AppLanguage get language => _language;

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
  }

  void cycleThemeMode() {
    setThemeMode(switch (_themeMode) {
      ThemeMode.system => ThemeMode.light,
      ThemeMode.light => ThemeMode.dark,
      ThemeMode.dark => ThemeMode.system,
    });
  }

  void setLanguage(AppLanguage language) {
    if (_language == language) return;
    _language = language;
    notifyListeners();
  }

  void toggleLanguage() {
    setLanguage(_language == AppLanguage.vi ? AppLanguage.en : AppLanguage.vi);
  }
}

class AppScope extends InheritedNotifier<AppSettingsController> {
  const AppScope({
    super.key,
    required AppSettingsController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppSettingsController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppScope>()?.notifier;
}

class AppStrings {
  const AppStrings(this.language);

  final AppLanguage language;

  bool get isVi => language == AppLanguage.vi;

  static AppStrings of(BuildContext context) {
    final lang = AppScope.maybeOf(context)?.language ?? AppLanguage.vi;
    return AppStrings(lang);
  }

  // Navigation & AppBar
  String get tabStations => isVi ? 'Điểm đo' : 'Stations';
  String get tabMap => isVi ? 'Bản đồ' : 'Map';
  String get tabAlerts => isVi ? 'Cảnh báo' : 'Alerts';
  String get tabWeather => isVi ? 'Thời tiết' : 'Weather';

  String get refreshDataTooltip => isVi ? 'Làm mới dữ liệu' : 'Refresh data';
  String get serverSettingsTooltip => 'Kết nối máy chủ';
  String get serverSettingsTitle =>
      isVi ? 'Kết nối máy chủ' : 'Server Connection';
  String get serverSettingsSubtitle => isVi
      ? 'Điện thoại và máy chủ cần cùng mạng. Nhập IP của máy tính chạy Flask.'
      : 'Phone and server must be on the same network. Enter the Flask host IP.';
  String get serverUrlLabel => isVi ? 'Địa chỉ máy chủ' : 'Server URL';
  String get serverSessionHint => isVi
      ? 'Địa chỉ được dùng trong phiên hiện tại. Bạn có thể đổi lại bất cứ lúc nào.'
      : 'This address applies to the current session and can be changed anytime.';
  String get cancel => isVi ? 'Hủy' : 'Cancel';
  String get connect => isVi ? 'Kết nối' : 'Connect';

  String get languageToggleTooltip =>
      isVi ? 'Chuyển sang tiếng Anh' : 'Switch to Vietnamese';
  String get themeModeTooltip => switch (isVi) {
    true => 'Giao diện Sáng / Tối',
    false => 'Light / Dark Theme',
  };
  String get preferencesTitle => isVi ? 'Tùy chọn hiển thị' : 'Display Settings';
  String get languageLabel => isVi ? 'Ngôn ngữ' : 'Language';
  String get themeLabel => isVi ? 'Chế độ giao diện' : 'Appearance';
  String get themeSystem => isVi ? 'Theo hệ thống' : 'System';
  String get themeLight => isVi ? 'Sáng' : 'Light';
  String get themeDark => isVi ? 'Tối' : 'Dark';

  // Tab headings
  String headingForTab(int tab) => switch (tab) {
    1 => isVi ? 'Bản đồ điểm đo' : 'Station Map',
    2 => isVi ? 'Theo dõi cảnh báo' : 'Heat Alerts',
    3 => isVi ? 'Thời tiết khu vực' : 'Regional Weather',
    _ => isVi ? 'Môi trường hôm nay' : 'Environment Today',
  };

  String subtitleForTab(int tab) => switch (tab) {
    1 => isVi
        ? 'Chạm ghim để xem nhanh số đo và kết nối'
        : 'Tap any pin to view live readings and status',
    2 => isVi
        ? 'Nhật ký các lần đo vượt ngưỡng an toàn'
        : 'Log of sensor readings exceeding thresholds',
    _ => isVi
        ? 'Giám sát nóng bức · Dữ liệu từ các trạm IoT'
        : 'Heat Monitoring · Live IoT Telemetry',
  };

  String syncedLabel(DateTime? syncedAt, bool hasError) {
    if (syncedAt == null) return '';
    final time = displayTime(syncedAt);
    if (isVi) {
      return '${!hasError ? 'Đồng bộ' : 'Dữ liệu đã lưu từ'} $time';
    }
    return '${!hasError ? 'Synced' : 'Cached from'} $time';
  }

  String get serverConnectFailedTitle =>
      isVi ? 'Chưa kết nối được máy chủ' : 'Cannot Reach Server';
  String get retry => isVi ? 'Thử lại' : 'Retry';

  // Hero network summary
  String networkBannerLabel(bool loading, bool hasError) {
    if (loading) return isVi ? 'ĐANG KẾT NỐI' : 'CONNECTING';
    if (hasError) return isVi ? 'MẤT KẾT NỐI MÁY CHỦ' : 'SERVER OFFLINE';
    return isVi ? 'MẠNG LƯỚI GIÁM SÁT' : 'MONITORING NETWORK';
  }

  String stationCountHeadline(int count, bool loading, bool emptyError) {
    if (loading || emptyError) {
      return isVi ? '— điểm đo' : '— stations';
    }
    return isVi ? '$count điểm đo' : '$count stations';
  }

  String activeCountText(int online) =>
      isVi ? '$online đang hoạt động' : '$online online';
  String warningCountText(int hot) =>
      isVi ? '$hot có cảnh báo' : '$hot alerts';
  String get autoSyncNote =>
      isVi ? 'Tự động đồng bộ mỗi 15 giây' : 'Auto-syncs every 15 seconds';

  // Map summary & controls
  String devicesCountChip(int count, bool loading) => loading
      ? (isVi ? 'Đang tải thiết bị…' : 'Loading devices…')
      : (isVi ? '$count thiết bị' : '$count devices');
  String onlineChip(int online) =>
      isVi ? '$online đang kết nối' : '$online connected';

  String get locateMe => isVi ? 'Định vị tôi' : 'Locate me';
  String get locatingLabel => isVi ? 'Đang định vị' : 'Locating';
  String get locatingStatus => isVi
      ? 'Đang kiểm tra quyền và lấy vị trí…'
      : 'Checking permission and fetching location…';
  String get allStationsTooltip => 'Tất cả điểm đo';
  String get zoomInTooltip => isVi ? 'Phóng to' : 'Zoom in';
  String get zoomOutTooltip => isVi ? 'Thu nhỏ' : 'Zoom out';
  String get openLocationSettings =>
      isVi ? 'Mở cài đặt quyền vị trí' : 'Open location settings';
  String get yourLocation => isVi ? 'Vị trí của bạn' : 'Your location';
  String get mapAttribution =>
      'Ảnh: Esri, Maxar, Earthstar Geographics, GIS User Community';
  String stationsAwaitingGps(int count) => isVi
      ? '$count điểm đo đang định vị, chưa có tọa độ hợp lệ.'
      : '$count stations locating, awaiting valid coordinates.';
  String get mapLegendSummary => isVi
      ? 'Ghim màu: đang kết nối  ·  Ghim xám: vị trí gần nhất'
      : 'Colored pin: connected  ·  Gray pin: last known';
  String get devicesOnMapTitle =>
      isVi ? 'Thiết bị trên bản đồ' : 'Stations on Map';
  String get devicesOnMapSubtitle => isVi
      ? 'Chọn trạm để xem số đo và tình trạng kết nối'
      : 'Select a station to inspect telemetry and connectivity';
  String get noStationsOnMapTitle =>
      isVi ? 'Chưa có trạm trên bản đồ' : 'No Stations on Map';
  String get noStationsOnMapSubtitle => isVi
      ? 'Thiết bị có tọa độ hợp lệ sẽ xuất hiện tại đây.'
      : 'Devices with valid coordinates will appear here.';

  // Station list & cards
  String get stationListTitle =>
      isVi ? 'Danh sách điểm đo' : 'Station Directory';
  String get stationListSubtitle => isVi
      ? 'Chọn một điểm để xem dữ liệu và dự báo'
      : 'Tap a station to view readings and forecasts';
  String get searchStationsLabel =>
      isVi ? 'Tìm tên hoặc mã điểm đo' : 'Search station name or ID';
  String get noStationsTitle => isVi ? 'Chưa có điểm đo' : 'No Stations Yet';
  String get noSearchResultsTitle =>
      isVi ? 'Không tìm thấy điểm đo' : 'No Matching Stations';
  String get noStationsMessage => isVi
      ? 'Bật ESP32 có kết nối MQTT. Thiết bị sẽ tự xuất hiện khi gửi dữ liệu.'
      : 'Power on an ESP32 connected to MQTT. Stations register automatically.';
  String get noSearchResultsMessage => isVi
      ? 'Thử tìm bằng tên hoặc mã thiết bị khác.'
      : 'Try another station name or device ID.';

  String get filterAll => isVi ? 'Tất cả' : 'All';
  String get filterOnline => isVi ? 'Trực tuyến' : 'Online';
  String get filterWarning => isVi ? 'Cảnh báo' : 'Alerts';

  // Metrics & Status
  String get heatIndexLabel => isVi ? 'Chỉ số nóng bức' : 'Heat Index';
  String get heatIndexCardHeader =>
      isVi ? 'Chỉ số nóng bức · ESP32' : 'Heat Index · ESP32';
  String get temperatureLabel => isVi ? 'Nhiệt độ' : 'Temperature';
  String get humidityLabel => isVi ? 'Độ ẩm' : 'Humidity';
  String get stationOnline => isVi ? 'Đang hoạt động' : 'Online';
  String get stationConnected => isVi ? 'Đang kết nối' : 'Connected';
  String get stationOfflineSignal =>
      isVi ? 'Chưa có tín hiệu mới' : 'No recent signal';
  String get stationLostSignal => isVi ? 'Mất tín hiệu' : 'Signal lost';
  String get stationAwaitingCoords =>
      isVi ? 'Chờ tọa độ từ ESP32' : 'Awaiting ESP32 coordinates';
  String get quickViewCachedNotice => isVi
      ? 'Đang hiển thị số đo gần nhất đã lưu.'
      : 'Showing the most recent saved reading.';
  String get viewDetails => isVi ? 'Xem chi tiết' : 'View Details';

  String warningLabel(int level) => isVi
      ? warningText(level)
      : switch (level) {
          2 => 'Extreme Danger',
          1 => 'Heat Advisory',
          0 => 'Safe',
          _ => 'No data',
        };

  String locationSourceLabel(String source) => isVi
      ? describeLocation(source)
      : switch (source) {
          'lbs' => '4G Network Estimate',
          'gps' => 'GPS ATGM336H',
          'gnss' => 'GPS/GNSS Fix',
          'manual' => 'Installed Location',
          _ => 'Saved Location',
        };

  String stationLocationDescription(Station station) {
    if (isVi) return station.locationDescription;
    if (!station.hasLocation) {
      return station.gpsValid == false ? 'No GPS fix yet' : 'Locating';
    }
    final fix = station.gpsValid == false
        ? ' · No GPS fix yet'
        : station.locationSource == 'gps' &&
              !station.isLastKnown &&
              station.satellites != null
        ? ' · ${station.satellites} satellites'
        : '';
    return '${station.isLastKnown ? 'Last known · ' : ''}${locationSourceLabel(station.locationSource)}$fix';
  }

  String relativeUpdateText(DateTime? value, {DateTime? now}) {
    if (isVi) return relativeUpdate(value, now: now);
    if (value == null) return 'No reading yet';
    final seconds = (now ?? DateTime.now())
        .difference(value)
        .inSeconds
        .clamp(0, 999999999);
    if (seconds < 5) return 'Updated just now';
    if (seconds < 60) return 'Updated ${seconds}s ago';
    if (seconds < 3600) return 'Updated ${seconds ~/ 60}m ago';
    if (seconds < 86400) return 'Updated ${seconds ~/ 3600}h ago';
    return 'Updated ${seconds ~/ 86400}d ago';
  }

  String locationOutcomeMessage(LocationOutcome outcome) {
    if (isVi) return outcome.message;
    return switch (outcome.status) {
      'success' =>
        'Your location · Accuracy ~${outcome.position!.accuracy.round()} m',
      'permission_denied' =>
        'Location permission denied. You can still enter the origin manually.',
      'permission_denied_forever' =>
        'Location permission blocked. Open settings or enter origin manually.',
      'services_declined' || 'deferred' =>
        'Deferred. You can continue using the map and manual origin.',
      'services_unavailable' =>
        'Location services unavailable. Check device settings or enter manually.',
      'timeout' =>
        'Could not get coordinates in time. Retry Locate me or enter manually.',
      'insecure_context' =>
        'HTTPS is required for browser location. You can still enter origin manually.',
      'browser_unavailable' =>
        'Device location unavailable. Enable Location in phone settings or enter manually.',
      'interrupted' => 'Location check stopped when leaving the app.',
      _ => 'Location unavailable. You can still enter the origin manually.',
    };
  }

  // Alerts tab
  String get alertLogTitle => isVi ? 'Nhật ký cảnh báo' : 'Alert Log';
  String get alertLogSubtitle => isVi
      ? 'Tối đa 100 lần đo mới nhất vượt ngưỡng cấu hình'
      : 'Up to 100 latest readings above thresholds';
  String get alertLoadErrorTitle =>
      isVi ? 'Không tải được cảnh báo' : 'Failed to Load Alerts';
  String get noAlertsTitle =>
      isVi ? 'Chưa ghi nhận cảnh báo' : 'No Alerts Recorded';
  String get noAlertsMessage => isVi
      ? 'Các lần đo có chỉ số nóng bức từ 32 °C sẽ xuất hiện tại đây.'
      : 'Readings with Heat Index ≥ 32 °C will appear here.';
  String get cachedAlertsNotice => isVi
      ? 'Đang hiển thị cảnh báo từ lần đồng bộ trước.'
      : 'Showing alerts from the previous sync.';
  String get thresholdScaleSafe => isVi ? '< 32°C An toàn' : '< 32°C Safe';
  String get thresholdScaleCaution =>
      isVi ? '32–38°C Cảnh báo' : '32–38°C Advisory';
  String get thresholdScaleDanger => isVi ? '≥ 38°C Nguy hiểm' : '≥ 38°C Danger';

  // Station detail screen
  String get refreshStationTooltip =>
      isVi ? 'Làm mới điểm đo' : 'Refresh station';
  String get stationRemovedNotice => isVi
      ? 'Điểm đo đã ngừng theo dõi hoặc không còn tồn tại.'
      : 'Station is paused or no longer exists.';
  String get currentDataStaleTitle => isVi
      ? 'Dữ liệu hiện tại chưa được làm mới'
      : 'Current Data Not Refreshed';
  String get offlineReadingNotice => isVi
      ? 'Thiết bị chưa gửi tín hiệu mới. Các chỉ số trên thuộc lần đo gần nhất.'
      : 'Device has not sent a new signal. Showing the latest saved reading.';
  String get locatingDetailMessage => isVi
      ? 'Đang định vị · Trạm chưa gửi tọa độ. Số đo vẫn được cập nhật.'
      : 'Locating · Station has not sent coordinates yet. Telemetry still updates.';
  String measurementTimeLabel(DateTime? dt) => isVi
      ? 'Lần đo: ${displayTime(dt)}'
      : 'Measured: ${dt == null ? 'No timestamp' : displayTime(dt)}';
  String locationUpdatedLabel(DateTime? dt) => isVi
      ? 'Cập nhật vị trí: ${displayTime(dt)}'
      : 'Location fix: ${dt == null ? 'No timestamp' : displayTime(dt)}';
  String coordinatesLabel(double lat, double lon) => isVi
      ? 'Vị trí: ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}'
      : 'Coordinates: ${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';

  String get forecast5hTitle =>
      isVi ? 'Dự báo 5 giờ tới' : '5-Hour Heat Forecast';
  String get forecast5hSubtitle => isVi
      ? 'Chỉ số nóng bức · Mô hình LSTM thử nghiệm'
      : 'Heat Index · Experimental LSTM Model';
  String get forecastUnavailableTitle =>
      isVi ? 'Chưa có dự báo' : 'Forecast Unavailable';
  String get forecastEmptyMessage => isVi
      ? 'Máy chủ chưa trả về kết quả dự báo.'
      : 'Server has not returned forecast values yet.';
  String forecastGeneratedAt(DateTime? dt) => isVi
      ? 'Tạo lúc ${displayTime(dt)}'
      : 'Generated ${displayTime(dt)}';
  String get forecastExperimentalFallback => isVi
      ? 'Mô hình thử nghiệm, được huấn luyện bằng dữ liệu mô phỏng.'
      : 'Experimental model trained on simulated data.';

  String get historyTitle => isVi ? 'Lịch sử đo' : 'Measurement History';
  String get historySubtitle => isVi
      ? 'Tối đa 200 lần đo trong khoảng đã chọn'
      : 'Up to 200 readings in selected range';
  String get timeframeTooltip => isVi ? 'Khoảng thời gian' : 'Timeframe';
  String get hours24 => isVi ? '24 giờ' : '24 hours';
  String get days7 => isVi ? '7 ngày' : '7 days';
  String get historyLoadErrorTitle =>
      isVi ? 'Không tải được lịch sử' : 'Failed to Load History';
  String get historyEmptyTitle => isVi
      ? 'Chưa có dữ liệu trong khoảng này'
      : 'No Data in This Period';
  String get historyEmptyMessage => isVi
      ? 'Chọn khoảng thời gian khác hoặc chờ thiết bị gửi dữ liệu.'
      : 'Try another timeframe or wait for the device to send data.';
  String get thresholdFootnote => isVi
      ? 'Ngưỡng cảnh báo theo cấu hình đồ án: từ 32 °C cảnh báo nóng; từ 38 °C cực kỳ nguy hiểm.'
      : 'Thresholds: ≥ 32 °C Heat Advisory; ≥ 38 °C Extreme Danger.';
  String get tableTime => isVi ? 'Thời gian' : 'Time';
  String get tableTemp => isVi ? 'Nhiệt độ' : 'Temp';
  String get tableHumidity => isVi ? 'Độ ẩm' : 'Humidity';
  String get tableHeatIndex => isVi ? 'Nóng bức' : 'Heat Index';
  String get historyTableNote => isVi
      ? 'Hiển thị tối đa 30 lần đo mới nhất; biểu đồ thể hiện toàn bộ kết quả đã tải.'
      : 'Showing up to 30 latest readings; chart reflects all loaded records.';
  String get statsMin => isVi ? 'Thấp nhất' : 'Min';
  String get statsAvg => isVi ? 'Trung bình' : 'Avg';
  String get statsMax => isVi ? 'Cao nhất' : 'Max';

  // Weather tab
  String get weatherHeader => isVi
      ? 'Thời tiết hiện tại từ Open-Meteo'
      : 'Current Weather from Open-Meteo';
  String get referenceStation =>
      isVi ? 'Điểm đo tham chiếu' : 'Reference Station';
  String get weatherLocationFailed => isVi
      ? 'Chưa lấy được vị trí. Kiểm tra quyền định vị hoặc chọn một điểm đo.'
      : 'Location unavailable. Check permissions or select a station.';
  String get weatherLocationHelp => isVi
      ? 'Khi bạn chọn dùng vị trí, tọa độ làm tròn được gửi để lấy thời tiết khu vực.'
      : 'When enabled, rounded coordinates are sent to fetch local weather.';
  String get useMyLocation => isVi ? 'Dùng vị trí của tôi' : 'Use my location';
  String get useStationWeather =>
      isVi ? 'Về thời tiết trạm' : 'Use station weather';
  String get refreshWeather =>
      isVi ? 'Làm mới thời tiết' : 'Refresh weather';
  String weatherLoadErrorTitle(String label) => isVi
      ? 'Chưa tải được thời tiết tại $label'
      : 'Unable to load weather at $label';
  String get cachedWeatherNotice => isVi
      ? 'Đang hiển thị lần tải gần nhất.'
      : 'Showing last loaded weather.';
  String get currentLabel => isVi ? 'Hiện tại' : 'Now';
  String get rainChance => isVi ? 'Khả năng mưa' : 'Rain chance';
  String rainChanceUntil(String time) =>
      isVi ? 'Khả năng mưa đến $time' : 'Rain chance until $time';
  String weatherUpdatedAt(String time) => isVi
      ? 'Cập nhật $time · Giờ tại vị trí xem'
      : 'Updated $time · Local time';
  String get yourArea => isVi ? 'Khu vực của bạn' : 'Your area';
  String get defaultCity =>
      isVi ? 'TP. Hồ Chí Minh · mặc định' : 'Ho Chi Minh City · default';
  String get forecastCardTitle =>
      isVi ? 'Dự báo nóng bức 5 giờ tới' : '5-Hour Heat Forecast';
  String get forecastCardSubtitle => isVi
      ? 'Mô hình LSTM thử nghiệm · Số đo ESP32'
      : 'Experimental LSTM · ESP32 Telemetry';
  String get loadingForecast =>
      isVi ? 'Đang tải dự báo LSTM…' : 'Loading LSTM forecast…';
  String get noStationForForecast => isVi
      ? 'Chưa có điểm đo để xem dự báo.'
      : 'Select a station to view forecast.';

  // Rain & heat route planner
  String get routePlannerTitle => isVi
      ? 'Tìm đường tránh nóng bức và hạn chế mưa'
      : 'Cool & Low-Rain Route Finder';
  String get routePlannerSubtitle => isVi
      ? 'Điểm đi thủ công hoặc vị trí của tôi'
      : 'Manual origin or my current location';
  String get routeOriginLabel => isVi ? 'Điểm đi' : 'Origin';
  String get routeDestLabel => isVi ? 'Điểm đến' : 'Destination';
  String get routeCoordHint => isVi
      ? 'Địa chỉ hoặc vĩ độ, kinh độ'
      : 'Address or latitude, longitude';
  String get routeOriginDefaultMsg => isVi
      ? 'Điểm đi mặc định là vị trí hiện tại. Có thể sửa lại; tọa độ chỉ được gửi khi bấm Tìm đường.'
      : 'Default origin is your location. Editable; coordinates are sent only on search.';
  String get vehicleLabel => isVi ? 'Phương tiện' : 'Vehicle';
  String get motorcycle => isVi ? 'Xe máy' : 'Motorcycle';
  String get car => isVi ? 'Ô tô' : 'Car';
  String get pickDepartureTitle =>
      isVi ? 'Chọn giờ khởi hành' : 'Schedule departure';
  String get leaveNow => isVi ? 'Đi ngay' : 'Leave now';
  String get deviceTime => isVi ? 'Giờ trên thiết bị' : 'Device time';
  String get chooseDateTime => isVi ? 'Chọn ngày giờ' : 'Pick date & time';
  String get findRoute => isVi ? 'Tìm đường' : 'Find route';
  String get findingRoute => isVi ? 'Đang tìm…' : 'Searching…';
  String get clearRoute => isVi ? 'Xóa tuyến' : 'Clear';
  String get selectDepartureFirst =>
      isVi ? 'Chọn ngày giờ khởi hành trước.' : 'Please select departure time.';
  String get searchingRoutesMsg => isVi
      ? 'Đang tìm tuyến và đánh giá nóng bức, mưa…'
      : 'Finding routes and evaluating heat & rain…';
  String get singleRouteOnly => isVi
      ? 'Chỉ tìm được một tuyến phù hợp.'
      : 'Only one suitable route was found.';
  String get chooseExactAddress =>
      isVi ? 'Chọn đúng địa chỉ' : 'Select Exact Address';
  String get routeRecommended =>
      isVi ? 'Tuyến phù hợp nhất' : 'Best Recommended';
  String get routeShortest => isVi ? 'Tuyến ngắn nhất' : 'Shortest Route';
  String get routeLowestRisk => isVi
      ? 'Tuyến ít nguy cơ nóng bức và mưa'
      : 'Lowest Heat & Rain Risk';
  String get routeUnavailable => isVi
      ? 'Chưa đủ dữ liệu nóng bức và mưa để xếp hạng'
      : 'Insufficient heat and rain data to rank';
  String get sameAsRecommended =>
      isVi ? 'Trùng với tuyến phù hợp nhất' : 'Same as recommended route';
  String get viewOnMap => isVi ? 'Xem trên bản đồ' : 'Show on map';
  String get viewingOnMap => isVi ? 'Đang hiển thị trên bản đồ' : 'Shown on map';
  String otherRoutesLabel(int count) =>
      isVi ? 'Tuyến khác ($count)' : 'Other routes ($count)';
  String get segmentDetailsTitle => isVi
      ? 'Nguồn dữ liệu từng đoạn của tuyến đang chọn'
      : 'Segment Data Sources for Selected Route';
  String get routeLegendColorNote => isVi
      ? 'Màu đoạn đường: xanh nguy cơ thấp, cam cảnh báo, đỏ nguy cơ cao, xám thiếu dữ liệu. Màu lấy mức cao hơn giữa nóng bức và mưa.'
      : 'Segment colors: green low risk, amber caution, red high risk, gray missing data. Color reflects the higher risk of heat or rain.';
  String get routeLegendSourceNote => isVi
      ? 'Nguồn chỉ số nóng bức: nét liền ESP32, nét chấm LSTM thử nghiệm, nét đứt Open-Meteo. Tuyến đường từ Valhalla/OpenStreetMap; mưa từ Open-Meteo.'
      : 'Heat sources: solid ESP32, dotted experimental LSTM, dashed Open-Meteo. Routing by Valhalla/OSM; rain by Open-Meteo.';

  String routeRiskLabel(RouteRisk risk) => isVi
      ? risk.label
      : switch (risk) {
          RouteRisk.low => 'Low',
          RouteRisk.moderate => 'Caution',
          RouteRisk.high => 'High',
          RouteRisk.unknown => 'Insufficient data',
        };

  String routeHeatSourceLabel(RouteHeatSource source) => isVi
      ? source.label
      : switch (source) {
          RouteHeatSource.esp32 => 'ESP32 + SHT31',
          RouteHeatSource.lstm => 'LSTM Forecast',
          RouteHeatSource.openMeteo => 'Open-Meteo Estimate',
          RouteHeatSource.unknown => 'No source',
        };
}
