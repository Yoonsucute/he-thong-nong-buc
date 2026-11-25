import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:he_thong_nong_buc/services/api_service.dart';

http.Response jsonResponse(Object? value, [int status = 200]) => http.Response(
  jsonEncode(value),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  test(
    'accepts LAN servers and rejects URLs that hide API paths or credentials',
    () {
      expect(
        ApiService.normalizeUrl(' http://192.168.1.10:5000/// '),
        'http://192.168.1.10:5000',
      );
      expect(
        ApiService.normalizeUrl('https://iot.example.test'),
        'https://iot.example.test',
      );
      for (final url in [
        '',
        'localhost:5000',
        'ftp://iot.test',
        'http://iot.test/api',
        'http://iot.test?key=secret',
        'http://user:password@iot.test',
        'http://iot.test#fragment',
      ]) {
        expect(
          () => ApiService.normalizeUrl(url),
          throwsA(isA<ApiException>()),
          reason: 'Reject $url',
        );
      }
    },
  );

  test(
    'loads enabled stations without inventing a reading for a new device',
    () async {
      final api = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient((request) async {
          expect(request.url.path, '/api/devices');
          return jsonResponse([
            {
              'device_id': 'A',
              'name': 'Trạm A',
              'enabled': true,
              'latest': null,
            },
            {'device_id': 'B', 'name': 'Trạm B', 'enabled': false},
            {'device_id': 'C', 'name': 'Trạm C', 'enabled': 0},
          ]);
        }),
      );
      addTearDown(api.close);
      final stations = await api.devices();
      expect(stations.map((station) => station.id), ['A']);
      expect(stations.single.name, 'Trạm A');
      expect(stations.single.latest, isNull);
      expect(stations.single.hasLocation, isFalse);
    },
  );

  test(
    'requests each station history with a UTC range and sorts results by time',
    () async {
      final api = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient((request) async {
          expect(request.url.path, '/api/sensor/history');
          final query = request.url.queryParameters;
          expect(query['device_id'], 'ESP 02');
          final start = DateTime.parse(query['start']!);
          final end = DateTime.parse(query['end']!);
          expect(start.isUtc, isTrue);
          expect(end.difference(start), const Duration(hours: 6));
          return jsonResponse([
            {
              'device_id': 'ESP 02',
              'heat_index': 35,
              'created_at': '2026-10-29T10:00:00+07:00',
            },
            {
              'device_id': 'ESP 02',
              'heat_index': 32,
              'created_at': '2026-10-29T09:00:00+07:00',
            },
          ]);
        }),
      );
      addTearDown(api.close);
      final rows = await api.history('ESP 02', hours: 6);
      expect(rows.map((row) => row.heatIndex), [32, 35]);
      expect(rows.every((row) => row.deviceId == 'ESP 02'), isTrue);
    },
  );

  test(
    'requests a forecast for the selected station and keeps its hourly times',
    () async {
      final api = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient((request) async {
          expect(request.url.path, '/api/sensor/forecast');
          expect(request.url.queryParameters['device_id'], 'ESP32_02');
          return jsonResponse({
            'device_id': 'ESP32_02',
            'forecast_next_5_hours': [31.0, 32.5, 34.0, 35.0, 33.0],
            'hourly': List.generate(
              5,
              (i) => {
                'time': '2026-10-29T${11 + i}:00:00+07:00',
                'heat_index': [31.0, 32.5, 34.0, 35.0, 33.0][i],
              },
            ),
            'model_status': 'experimental',
            'model_note': 'Mô hình huấn luyện trên dữ liệu mô phỏng.',
          });
        }),
      );
      addTearDown(api.close);
      final forecast = await api.forecast('ESP32_02');
      expect(forecast.values, [31.0, 32.5, 34.0, 35.0, 33.0]);
      expect(forecast.times.length, 5);
      expect(
        forecast.times[1]!.difference(forecast.times[0]!),
        const Duration(hours: 1),
      );
      expect(forecast.modelStatus, 'experimental');
      expect(forecast.modelNote, contains('mô phỏng'));
    },
  );

  test(
    'preserves forecast-unavailable error instead of supplying sample numbers',
    () async {
      final api = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient(
          (_) async =>
              jsonResponse({'error': 'Chưa đủ 12 giờ dữ liệu liên tiếp.'}, 422),
        ),
      );
      addTearDown(api.close);
      await expectLater(
        api.forecast('A'),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('12 giờ'),
          ),
        ),
      );
    },
  );

  test(
    'reports a server outage and invalid JSON as user-readable errors',
    () async {
      final outage = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient((_) async {
          throw http.ClientException('Connection refused');
        }),
      );
      final invalid = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient(
          (_) async => http.Response('<html>server error</html>', 502),
        ),
      );
      addTearDown(outage.close);
      addTearDown(invalid.close);
      await expectLater(
        outage.devices(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('Không kết nối'),
          ),
        ),
      );
      await expectLater(
        invalid.devices(),
        throwsA(
          isA<ApiException>().having(
            (error) => error.message,
            'message',
            contains('không hợp lệ'),
          ),
        ),
      );
    },
  );

  test('rejects an object where a station list is required', () async {
    final api = ApiService(
      baseUrl: 'http://iot.test',
      client: MockClient((_) async => jsonResponse({'devices': []})),
    );
    addTearDown(api.close);
    await expectLater(api.devices(), throwsA(isA<ApiException>()));
  });

  test(
    'loads alert measurements with device identity and original timestamps',
    () async {
      final api = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient((request) async {
          expect(request.url.path, '/api/alerts');
          return jsonResponse([
            {
              'device_id': 'ESP32_02',
              'heat_index': '39.2',
              'created_at': '2026-10-29T11:00:00+07:00',
            },
          ]);
        }),
      );
      addTearDown(api.close);
      final rows = await api.alerts();
      expect(rows.single.deviceId, 'ESP32_02');
      expect(rows.single.heatIndex, 39.2);
      expect(rows.single.level, 2);
      expect(rows.single.createdAt!.toUtc(), DateTime.utc(2026, 10, 29, 4));
    },
  );

  test(
    'device refresh keeps the server location fix time separate from new telemetry',
    () async {
      var refresh = 0;
      final api = ApiService(
        baseUrl: 'http://iot.test',
        client: MockClient((request) async {
          expect(request.url.path, '/api/devices');
          final minute = refresh++ == 0 ? '05' : '06';
          return jsonResponse([
            {
              'device_id': 'ESP32_LBS',
              'name': 'ESP32 sân trường',
              'enabled': true,
              'is_online': true,
              'latitude': 10.77,
              'longitude': 106.70,
              'location_source': 'lbs',
              'location_updated_at': '2026-10-29T10:00:00+07:00',
              'latest': {
                'device_id': 'ESP32_LBS',
                'created_at': '2026-10-29T10:$minute:00+07:00',
                'heat_index': 34,
              },
            },
          ]);
        }),
      );
      addTearDown(api.close);
      final first = (await api.devices()).single;
      final second = (await api.devices()).single;
      expect(first.locationSource, 'lbs');
      expect(
        second.locationDescription,
        contains('Vị trí ước lượng qua mạng 4G'),
      );
      expect(second.locationUpdatedAt, first.locationUpdatedAt);
      expect(
        second.latest!.createdAt!.difference(first.latest!.createdAt!),
        const Duration(minutes: 1),
      );
    },
  );
}
