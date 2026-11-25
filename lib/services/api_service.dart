import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/sensor.dart';
import '../models/rain_route.dart';
import '../models/weather.dart';
import 'package:latlong2/latlong.dart';

class ApiException implements Exception {
  const ApiException(this.message);
  final String message;
  @override
  String toString() => message;
}

class ApiService {
  ApiService({String? baseUrl, http.Client? client})
    : baseUrl = normalizeUrl(baseUrl ?? defaultBaseUrl),
      _client = client ?? http.Client();

  static String get defaultBaseUrl {
    const configured = String.fromEnvironment('API_BASE_URL');
    if (configured.isNotEmpty) return configured;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      return 'http://10.0.2.2:5000';
    }
    return 'http://127.0.0.1:5000';
  }

  static String normalizeUrl(String value) {
    final clean = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(clean);
    if (uri == null ||
        !['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        uri.userInfo.isNotEmpty ||
        (uri.path.isNotEmpty && uri.path != '/')) {
      throw const ApiException(
        'Nhập địa chỉ máy chủ, ví dụ http://192.168.1.10:5000',
      );
    }
    return clean;
  }

  final String baseUrl;
  final http.Client _client;
  void close() => _client.close();

  Future<dynamic> _get(
    String path, [
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 12),
  ]) async {
    try {
      final response = await _client
          .get(Uri.parse('$baseUrl$path').replace(queryParameters: query))
          .timeout(timeout);
      dynamic body;
      try {
        body = jsonDecode(utf8.decode(response.bodyBytes));
      } on FormatException {
        throw const ApiException('Máy chủ trả về dữ liệu không hợp lệ.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ApiException(
          body is Map
              ? '${body['error'] ?? 'Không thể tải dữ liệu.'}'
              : 'Máy chủ trả về lỗi ${response.statusCode}.',
        );
      }
      return body;
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Không kết nối được máy chủ. Kiểm tra địa chỉ và mạng Wi-Fi.',
      );
    }
  }

  Future<List<Station>> devices() async {
    final data = await _get('/api/devices');
    if (data is! List) {
      throw const ApiException('Danh sách điểm đo không hợp lệ.');
    }
    return data
        .map((e) => Station.fromJson(Map<String, dynamic>.from(e as Map)))
        .where((e) => e.enabled)
        .toList();
  }

  Future<LocalWeather> weather(LatLng point) async {
    final latitude = point.latitude.toStringAsFixed(2);
    final longitude = point.longitude.toStringAsFixed(2);
    final data = await _get('/api/weather', {
      'point': '$latitude,$longitude',
      'current_only': '1',
    }, const Duration(seconds: 15));
    try {
      return LocalWeather.fromJson(data as Map<String, dynamic>);
    } catch (_) {
      throw const ApiException('Dữ liệu thời tiết không hợp lệ.');
    }
  }

  Future<List<Map<String, dynamic>>> geocode(String query) async {
    final data = await _get('/api/rain-route/geocode', {'q': query});
    if (data is! Map || data['results'] is! List) {
      throw const ApiException('Không đọc được địa chỉ.');
    }
    return (data['results'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
  }

  Future<RainPlan> rainRoute(
    LatLng start,
    LatLng end,
    String vehicle,
    DateTime? departure,
  ) async {
    final data = await _get('/api/rain-route', {
      'start': '${start.latitude},${start.longitude}',
      'end': '${end.latitude},${end.longitude}',
      'vehicle': vehicle,
      'departure': departure?.toUtc().toIso8601String() ?? 'now',
    }, const Duration(seconds: 80));
    try {
      final plan = RainPlan(Map<String, dynamic>.from(data as Map));
      if (plan.routes.isEmpty ||
          !plan.routes.any((r) => r.id == plan.shortestId) ||
          plan.routes.any(
            (r) =>
                r.geometry.length < 2 ||
                r.segments.any(
                  (s) =>
                      s.start < 0 ||
                      s.end <= s.start ||
                      s.end >= r.geometry.length,
                ),
          )) {
        throw const FormatException();
      }
      return plan;
    } catch (_) {
      throw const ApiException('Dữ liệu tuyến đường không hợp lệ.');
    }
  }

  Future<List<Reading>> history(String id, {int hours = 24}) async {
    final now = DateTime.now().toUtc();
    final data = await _get('/api/sensor/history', {
      'device_id': id,
      'limit': '200',
      'start': now.subtract(Duration(hours: hours)).toIso8601String(),
      'end': now.toIso8601String(),
    });
    if (data is! List) throw const ApiException('Lịch sử đo không hợp lệ.');
    final rows = data
        .map((e) => Reading.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
    rows.sort(
      (a, b) => (a.createdAt ?? DateTime(1970)).compareTo(
        b.createdAt ?? DateTime(1970),
      ),
    );
    return rows;
  }

  Future<Forecast> forecast(String id) async {
    final data = await _get('/api/sensor/forecast', {'device_id': id});
    if (data is! Map || data['forecast_next_5_hours'] is! List) {
      throw const ApiException('Kết quả dự báo không hợp lệ.');
    }
    final values = data['forecast_next_5_hours'] as List;
    if (values.length != 5 || values.any((e) => number(e) == null)) {
      throw const ApiException('Máy chủ chưa trả về đủ 5 giờ dự báo hợp lệ.');
    }
    return Forecast.fromJson(Map<String, dynamic>.from(data));
  }

  Future<List<Reading>> alerts() async {
    final data = await _get('/api/alerts', {'limit': '100'});
    if (data is! List) {
      throw const ApiException('Danh sách cảnh báo không hợp lệ.');
    }
    return data
        .map((e) => Reading.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Luồng Server-Sent Events (SSE) nhận cảnh báo nóng bức trực tiếp từ Flask.
  Stream<Reading> alertStream() {
    final controller = StreamController<Reading>();
    final sseClient = http.Client();
    StreamSubscription<String>? lineSub;

    () async {
      try {
        final request = http.Request('GET', Uri.parse('$baseUrl/api/alerts/stream'))
          ..headers['Accept'] = 'text/event-stream'
          ..headers['Cache-Control'] = 'no-cache';
        final response = await sseClient
            .send(request)
            .timeout(const Duration(seconds: 15));
        if (response.statusCode < 200 || response.statusCode >= 300) {
          throw ApiException('SSE lỗi ${response.statusCode}');
        }
        String currentEvent = '';
        final dataLines = <String>[];
        lineSub = response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .listen(
              (line) {
                if (line.isEmpty) {
                  if (currentEvent == 'alert' && dataLines.isNotEmpty) {
                    try {
                      final raw = jsonDecode(dataLines.join('\n'));
                      if (raw is Map) {
                        controller.add(
                          Reading.fromJson(Map<String, dynamic>.from(raw)),
                        );
                      }
                    } catch (_) {}
                  }
                  currentEvent = '';
                  dataLines.clear();
                } else if (line.startsWith('event:')) {
                  currentEvent = line.substring(6).trim();
                } else if (line.startsWith('data:')) {
                  dataLines.add(line.substring(5).trim());
                }
              },
              onError: (Object error, StackTrace st) {
                if (!controller.isClosed) controller.addError(error, st);
              },
              onDone: () {
                if (!controller.isClosed) controller.close();
              },
              cancelOnError: true,
            );
      } catch (error, st) {
        if (!controller.isClosed) {
          controller.addError(error, st);
          await controller.close();
        }
      }
    }();

    controller.onCancel = () async {
      await lineSub?.cancel();
      sseClient.close();
    };
    return controller.stream;
  }
}
