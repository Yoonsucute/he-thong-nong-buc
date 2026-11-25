double? number(Object? value) {
  final parsed = value is num ? value.toDouble() : double.tryParse('$value');
  return parsed != null && parsed.isFinite ? parsed : null;
}

DateTime? parseTime(Object? value) {
  if (value == null || '$value'.isEmpty) return null;
  return DateTime.tryParse('$value')?.toLocal();
}

String displayTime(DateTime? value, {bool date = true}) {
  if (value == null) return 'Chưa có thời gian cập nhật';
  String pad(int n) => n.toString().padLeft(2, '0');
  final time = '${pad(value.hour)}:${pad(value.minute)}';
  return date
      ? '$time · ${pad(value.day)}/${pad(value.month)}/${value.year}'
      : time;
}

String measurement(double? value, [String unit = '°C']) =>
    value == null ? '—' : '${value.toStringAsFixed(1)} $unit';

String relativeUpdate(DateTime? value, {DateTime? now}) {
  if (value == null) return 'Chưa có số đo';
  final seconds = (now ?? DateTime.now())
      .difference(value)
      .inSeconds
      .clamp(0, 999999999);
  if (seconds < 5) return 'Cập nhật vừa xong';
  if (seconds < 60) return 'Cập nhật $seconds giây trước';
  if (seconds < 3600) return 'Cập nhật ${seconds ~/ 60} phút trước';
  if (seconds < 86400) return 'Cập nhật ${seconds ~/ 3600} giờ trước';
  return 'Cập nhật ${seconds ~/ 86400} ngày trước';
}

// Ngưỡng thống nhất với cấu hình cảnh báo của máy chủ đồ án.
int warningLevel(double? heatIndex) =>
    heatIndex == null ? -1 : (heatIndex >= 38 ? 2 : (heatIndex >= 32 ? 1 : 0));

String warningText(int level) => switch (level) {
  2 => 'Cực kỳ nguy hiểm',
  1 => 'Cảnh báo nóng',
  0 => 'An toàn',
  _ => 'Chưa có dữ liệu',
};

String describeLocation(String source) => switch (source) {
  'lbs' => 'Vị trí ước lượng qua mạng 4G',
  'gps' => 'GPS ATGM336H',
  'gnss' => 'Vị trí GPS/GNSS',
  'manual' => 'Vị trí lắp đặt',
  _ => 'Vị trí đã lưu',
};

class Reading {
  Reading.fromJson(Map<String, dynamic> json)
    : deviceId = '${json['device_id'] ?? ''}',
      temperature = number(json['temperature']),
      humidity = number(json['humidity']),
      heatIndex = number(json['heat_index']),
      latitude = number(json['latitude']),
      longitude = number(json['longitude']),
      createdAt = parseTime(json['created_at']),
      locationSource = '${json['location_source'] ?? 'unknown'}',
      locationUpdatedAt = parseTime(json['location_updated_at']);

  final String deviceId;
  final double? temperature, humidity, heatIndex, latitude, longitude;
  final DateTime? createdAt;
  final String locationSource;
  final DateTime? locationUpdatedAt;
  int get level => warningLevel(heatIndex);
}

class Station {
  Station.fromJson(Map<String, dynamic> json)
    : id = '${json['device_id'] ?? ''}',
      name = '${json['name'] ?? json['device_id'] ?? 'Điểm đo'}',
      latitude = number(json['latitude']),
      longitude = number(json['longitude']),
      online = json['is_online'] == true,
      enabled = json['enabled'] != false && json['enabled'] != 0,
      lastSeen = parseTime(json['last_seen']),
      _locationSource = '${json['location_source'] ?? 'unknown'}',
      locationPending = json['location_pending'] == true,
      locationStatus = '${json['location_status'] ?? ''}',
      gpsValid = json['gps_valid'] is bool ? json['gps_valid'] as bool : null,
      satellites = json['satellites'] is int ? json['satellites'] as int : null,
      _locationUpdatedAt = parseTime(json['location_updated_at']),
      latest = json['latest'] is Map
          ? Reading.fromJson(Map<String, dynamic>.from(json['latest'] as Map))
          : null;

  final String id, name;
  final double? latitude, longitude;
  final bool online, enabled;
  final DateTime? lastSeen;
  final String _locationSource;
  final bool locationPending;
  final String locationStatus;
  final bool? gpsValid;
  final int? satellites;
  final DateTime? _locationUpdatedAt;
  final Reading? latest;
  // Latitude and longitude must come from the same complete coordinate pair.
  // Never combine a saved latitude with a longitude from another reading.
  ({double latitude, double longitude, String source, DateTime? updatedAt})?
  get location {
    if (locationStatus == 'unavailable') return null;
    bool valid(double? lat, double? lng) =>
        lat != null &&
        lng != null &&
        lat.abs() <= 90 &&
        lng.abs() <= 180 &&
        (lat != 0 || lng != 0);
    if (valid(latitude, longitude)) {
      return (
        latitude: latitude!,
        longitude: longitude!,
        source: _locationSource,
        updatedAt: _locationUpdatedAt,
      );
    }
    if (valid(latest?.latitude, latest?.longitude)) {
      return (
        latitude: latest!.latitude!,
        longitude: latest!.longitude!,
        source: latest!.locationSource,
        updatedAt: latest!.locationUpdatedAt,
      );
    }
    return null;
  }

  double? get mapLatitude => location?.latitude;
  double? get mapLongitude => location?.longitude;
  String get locationSource => location?.source ?? _locationSource;
  DateTime? get locationUpdatedAt =>
      location == null ? _locationUpdatedAt : location!.updatedAt;
  bool get isLastKnown =>
      hasLocation &&
      locationSource != 'manual' &&
      (locationPending ||
          locationStatus == 'last_known' ||
          !online ||
          (locationUpdatedAt != null &&
              DateTime.now().difference(locationUpdatedAt!).inSeconds >
                  (locationSource == 'lbs' ? 600 : 120)));
  String get locationDescription {
    if (!hasLocation) {
      return gpsValid == false ? 'Chưa bắt được GPS' : 'Đang định vị';
    }
    final fix = gpsValid == false
        ? ' · Chưa bắt được GPS'
        : locationSource == 'gps' && !isLastKnown && satellites != null
        ? ' · $satellites vệ tinh'
        : '';
    return '${isLastKnown ? 'Vị trí gần nhất · ' : ''}${describeLocation(locationSource)}$fix';
  }

  bool get hasLocation => location != null;
}

class Forecast {
  Forecast.fromJson(Map<String, dynamic> json)
    : values = (json['forecast_next_5_hours'] as List? ?? [])
          .map(number)
          .whereType<double>()
          .toList(),
      times = (json['hourly'] as List? ?? [])
          .map((item) => item is Map ? parseTime(item['time']) : null)
          .toList(),
      generatedAt = parseTime(json['generated_at']),
      modelStatus = '${json['model_status'] ?? ''}',
      modelNote = '${json['model_note'] ?? ''}';

  final List<double> values;
  final List<DateTime?> times;
  final DateTime? generatedAt;
  final String modelStatus, modelNote;
}
