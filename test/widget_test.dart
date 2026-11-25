import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'package:he_thong_nong_buc/main.dart';
import 'package:he_thong_nong_buc/models/sensor.dart';
import 'package:he_thong_nong_buc/services/api_service.dart';
import 'package:he_thong_nong_buc/widgets/station_map.dart';

Map<String, Object?> station(
  String id,
  String name, {
  bool hasReading = true,
}) => {
  'device_id': id,
  'name': name,
  'enabled': true,
  'is_online': true,
  'latitude': 10.77,
  'longitude': 106.70,
  'last_seen': '2026-10-29T11:00:00+07:00',
  'latest': hasReading
      ? {
          'device_id': id,
          'temperature': 31.2,
          'humidity': 65,
          'heat_index': 35.1,
          'latitude': 10.77,
          'longitude': 106.70,
          'created_at': '2026-10-29T11:00:00+07:00',
        }
      : null,
};

http.Response respond(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

Map<String, Object?> mockWeather() => {
  'source': 'Open-Meteo',
  'current': {
    'time': '2026-11-21T14:30+07:00',
    'temperature': 29,
    'humidity': 71,
    'rain_probability': 42,
    'rain_until': '2026-11-21T15:00+07:00',
    'icon': 'partly-cloudy',
    'description': 'Mây rải rác',
  },
  'hourly': [
    for (var i = 0; i < 12; i++)
      {
        'time': DateTime(2026, 11, 21, 15 + i).toIso8601String(),
        'temperature': 28.5 - i * .3,
        'humidity': 75 + i,
        'rain_probability': 42 + i,
        'icon': i < 4 ? 'rain' : 'cloudy',
        'description': i < 4 ? 'Mưa rào' : 'Nhiều mây',
      },
  ],
};

Map<String, Object?> mockForecast(String? deviceId) => {
  'device_id': deviceId,
  'forecast_next_5_hours': [35, 36, 37, 36, 35],
  'hourly': [
    for (final (id, heat) in [35, 36, 37, 36, 35].indexed)
      {'time': '2026-10-29T${12 + id}:00:00+07:00', 'heat_index': heat},
  ],
  'model_status': 'experimental',
  'model_note': 'Mô hình huấn luyện trên dữ liệu mô phỏng.',
};

ApiService fixtureApi({
  List<Map<String, Object?>>? devices,
  List<Uri>? requests,
}) => ApiService(
  baseUrl: 'http://iot.test',
  client: MockClient((request) async {
    requests?.add(request.url);
    switch (request.url.path) {
      case '/api/devices':
        return respond(devices ?? [station('ESP32_01', 'Trạm Bình Dương')]);
      case '/api/alerts':
        return respond([]);
      case '/api/weather':
        return respond(mockWeather());
      case '/api/sensor/history':
        return respond([
          {
            'device_id': request.url.queryParameters['device_id'],
            'heat_index': 34.0,
            'temperature': 30.0,
            'humidity': 65,
            'created_at': '2026-10-29T10:00:00+07:00',
          },
          {
            'device_id': request.url.queryParameters['device_id'],
            'heat_index': 35.1,
            'temperature': 31.2,
            'humidity': 65,
            'created_at': '2026-10-29T11:00:00+07:00',
          },
        ]);
      case '/api/sensor/forecast':
        return respond(mockForecast(request.url.queryParameters['device_id']));
      default:
        return respond({'error': 'Endpoint not mocked'}, 404);
    }
  }),
);

void phoneSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<void> showStationList(WidgetTester tester) async {
  await tester.tap(find.text('Điểm đo').last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('all station pin labels fit inside the map away from controls', (
    tester,
  ) async {
    phoneSize(tester, const Size(390, 844));
    final points = [(10.7769, 106.7009), (10.85, 106.76), (10.72, 106.65)];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StationMap(
            stations: [
              for (var i = 0; i < points.length; i++)
                Station.fromJson(
                  station('PIN_$i', 'Điểm đo $i')
                    ..['latitude'] = points[i].$1
                    ..['longitude'] = points[i].$2,
                ),
            ],
            loadTiles: false,
            onSelect: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final map = tester.getRect(find.byType(FlutterMap));
    for (var i = 0; i < points.length; i++) {
      final pin = tester.getRect(find.byKey(ValueKey('device-pin-PIN_$i')));
      expect(pin.top, greaterThanOrEqualTo(map.top));
      expect(pin.left, greaterThanOrEqualTo(map.left));
      expect(pin.right, lessThanOrEqualTo(map.right - 54));
      expect(pin.bottom, lessThanOrEqualTo(map.bottom));
    }
    expect(tester.takeException(), isNull);
  });
  testWidgets('quick view stays current while polling on a narrow phone', (
    tester,
  ) async {
    phoneSize(tester, const Size(320, 700));
    final devices = [station('LIVE', 'Trạm cập nhật trực tiếp')];
    final api = fixtureApi(devices: devices);
    addTearDown(api.close);
    await tester.pumpWidget(MyApp(api: api, loadMapTiles: false));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('device-pin-LIVE')));
    await tester.pumpAndSettle();
    expect(find.text('Xem chi tiết'), findsOneWidget);
    final latest = devices.single['latest'] as Map<String, Object?>;
    latest['heat_index'] = 37.2;
    await tester.pump(const Duration(seconds: 15));
    await tester.pumpAndSettle();
    expect(find.text('37.2'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'open app polls a new device, first GPS fix, movement and failed fix',
    (tester) async {
      phoneSize(tester, const Size(390, 844));
      final devices = <Map<String, Object?>>[];
      final api = fixtureApi(devices: devices);
      addTearDown(api.close);
      await tester.pumpWidget(MyApp(api: api, loadMapTiles: false));
      await tester.pumpAndSettle();
      final pending = station('AUTO_GPS', 'AUTO_GPS', hasReading: false)
        ..['latitude'] = null
        ..['longitude'] = null
        ..['gps_valid'] = false
        ..['location_pending'] = true;
      devices.add(pending);
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      final pin = find.byKey(const ValueKey('device-pin-AUTO_GPS'));
      expect(pin, findsNothing);
      expect(find.textContaining('Chưa bắt được GPS'), findsWidgets);
      pending.addAll({
        'latitude': 21.5,
        'longitude': 105.4,
        'location_source': 'gps',
        'location_updated_at': DateTime.now().toIso8601String(),
        'location_pending': false,
        'gps_valid': true,
        'satellites': 8,
      });
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<StationMap>(find.byType(StationMap))
            .stations
            .single
            .hasLocation,
        isTrue,
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(pin, findsOneWidget);
      final controller = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!;
      expect(controller.camera.center.latitude, closeTo(21.5, .0001));
      pending.addAll({'latitude': 21.501, 'longitude': 105.401});
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(pin, findsOneWidget);
      final marker = tester
          .widgetList<MarkerLayer>(find.byType(MarkerLayer))
          .expand((layer) => layer.markers)
          .singleWhere(
            (m) => m.child.key == const ValueKey('device-pin-AUTO_GPS'),
          );
      expect(marker.point.latitude, 21.501);
      expect(marker.point.longitude, 105.401);
      pending['location_pending'] = true;
      pending['gps_valid'] = false;
      await tester.pump(const Duration(seconds: 15));
      await tester.pumpAndSettle();
      expect(pin, findsOneWidget);
      expect(find.textContaining('Vị trí gần nhất'), findsWidgets);
      expect(find.text('GPS ATGM336H'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final size in [const Size(390, 844), const Size(320, 700)]) {
    testWidgets('station list fits a ${size.width.toInt()}px phone', (
      tester,
    ) async {
      phoneSize(tester, size);
      final api = fixtureApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MyApp(api: api, autoRefresh: false, loadMapTiles: false),
      );
      await tester.pumpAndSettle();
      await showStationList(tester);
      expect(find.text('HeatWatch'), findsWidgets);
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(find.text('Điểm đo'), findsWidgets);
      expect(find.text('Bản đồ'), findsWidgets);
      expect(find.text('Cảnh báo'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a station with no reading is not shown as zero degrees', (
    tester,
  ) async {
    phoneSize(tester, const Size(390, 844));
    final api = fixtureApi(
      devices: [station('NEW', 'Điểm đo mới', hasReading: false)],
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MyApp(api: api, autoRefresh: false, loadMapTiles: false),
    );
    await tester.pumpAndSettle();
    await showStationList(tester);
    expect(find.text('0.0 °C'), findsNothing);
    expect(find.text('0.0 %'), findsNothing);
    expect(find.text('Chưa có dữ liệu'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows loading while a device request is pending', (
    tester,
  ) async {
    final response = Completer<http.Response>();
    final api = ApiService(
      baseUrl: 'http://iot.test',
      client: MockClient((request) async {
        if (request.url.path == '/api/devices') return response.future;
        return respond([]);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MyApp(api: api, autoRefresh: false, loadMapTiles: false),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsWidgets);
    response.complete(respond([]));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'search opens the selected station and loads only its history and forecast',
    (tester) async {
      phoneSize(tester, const Size(320, 700));
      final requests = <Uri>[];
      final api = fixtureApi(
        devices: [
          station('ESP32_01', 'Trạm Bình Dương'),
          station('ESP32_02', 'Trạm Thủ Đức'),
        ],
        requests: requests,
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MyApp(api: api, autoRefresh: false, loadMapTiles: false),
      );
      await tester.pumpAndSettle();
      await showStationList(tester);
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'ESP32_02');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      expect(find.text('Trạm Bình Dương'), findsNothing);
      await tester.ensureVisible(find.text('Trạm Thủ Đức'));
      await tester.tap(find.text('Trạm Thủ Đức'));
      await tester.pumpAndSettle();
      expect(find.text('Dự báo 5 giờ tới'), findsOneWidget);
      expect(find.text('Lịch sử đo'), findsOneWidget);
      final detailRequests = requests.where(
        (uri) =>
            uri.path == '/api/sensor/history' ||
            uri.path == '/api/sensor/forecast',
      );
      expect(detailRequests.length, 2);
      expect(
        detailRequests.every(
          (uri) => uri.queryParameters['device_id'] == 'ESP32_02',
        ),
        isTrue,
      );
      await tester.ensureVisible(find.text('Dự báo 5 giờ tới'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('map navigation fits the phone without loading remote tiles', (
    tester,
  ) async {
    phoneSize(tester, const Size(320, 700));
    final api = fixtureApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MyApp(api: api, autoRefresh: false, loadMapTiles: false),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<NavigationBar>(find.byType(NavigationBar)).selectedIndex,
      1,
    );
    expect(find.text('Bản đồ điểm đo'), findsOneWidget);
    expect(find.byKey(const ValueKey('device-pin-ESP32_01')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline ESP32 keeps its saved pin and opens its own detail', (
    tester,
  ) async {
    phoneSize(tester, const Size(390, 844));
    final saved = station('ESP32_OFFLINE', 'ESP32 sân trường')
      ..['is_online'] = false
      ..['location_source'] = 'lbs'
      ..['location_updated_at'] = '2026-10-29T09:00:00+07:00';
    final requests = <Uri>[];
    final api = fixtureApi(devices: [saved], requests: requests);
    addTearDown(api.close);
    await tester.pumpWidget(
      MyApp(api: api, autoRefresh: false, loadMapTiles: false),
    );
    await tester.pumpAndSettle();

    final pin = find.byKey(const ValueKey('device-pin-ESP32_OFFLINE'));
    expect(pin, findsOneWidget);
    expect(find.textContaining('ESP32_OFFLINE'), findsWidgets);
    await tester.ensureVisible(pin);
    await tester.tap(pin);
    await tester.pumpAndSettle();
    expect(find.text('Xem chi tiết'), findsOneWidget);
    await tester.ensureVisible(find.text('Xem chi tiết'));
    await tester.tap(find.text('Xem chi tiết'));
    await tester.pumpAndSettle();
    expect(find.text('Dự báo 5 giờ tới'), findsOneWidget);
    expect(find.textContaining('Vị trí ước lượng qua mạng 4G'), findsWidgets);
    expect(
      find.textContaining(
        'Cập nhật vị trí: ${displayTime(parseTime('2026-10-29T09:00:00+07:00'))}',
      ),
      findsOneWidget,
    );
    final details = requests.where(
      (uri) => uri.path.startsWith('/api/sensor/'),
    );
    expect(details, isNotEmpty);
    expect(
      details.every(
        (uri) => uri.queryParameters['device_id'] == 'ESP32_OFFLINE',
      ),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'LBS pin and detail identify an approximate fix with its own timestamp',
    (tester) async {
      phoneSize(tester, const Size(320, 700));
      final lbs = station('ESP32_LBS', 'ESP32 cổng trường')
        ..['location_source'] = 'lbs'
        ..['location_updated_at'] = '2026-10-29T10:50:00+07:00';
      final api = fixtureApi(devices: [lbs]);
      addTearDown(api.close);
      await tester.pumpWidget(
        MyApp(api: api, autoRefresh: false, loadMapTiles: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('LBS · Ước lượng'), findsWidgets);
      final pin = find.byKey(const ValueKey('device-pin-ESP32_LBS'));
      await tester.ensureVisible(pin);
      await tester.tap(pin);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Xem chi tiết'));
      await tester.tap(find.text('Xem chi tiết'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Vị trí ước lượng qua mạng 4G'), findsWidgets);
      expect(
        find.textContaining(
          'Cập nhật vị trí: ${displayTime(parseTime('2026-10-29T10:50:00+07:00'))}',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Lần đo: ${displayTime(parseTime('2026-10-29T11:00:00+07:00'))}',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('device with no valid coordinate pair has no invented map pin', (
    tester,
  ) async {
    phoneSize(tester, const Size(390, 844));
    final unknown =
        station('ESP32_NO_GPS', 'ESP32 chưa có vị trí', hasReading: false)
          ..['latitude'] = null
          ..['longitude'] = null;
    final api = fixtureApi(devices: [unknown]);
    addTearDown(api.close);
    await tester.pumpWidget(
      MyApp(api: api, autoRefresh: false, loadMapTiles: false),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('device-pin-ESP32_NO_GPS')), findsNothing);
    expect(find.textContaining('chưa có tọa độ'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('map focuses the first device arriving after an empty response', (
    tester,
  ) async {
    phoneSize(tester, const Size(390, 844));
    List<Station> devices = [];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return StationMap(
                stations: devices,
                loadTiles: false,
                onSelect: (_) {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => devices = [Station.fromJson(station('A', 'ESP32 A'))]);
    await tester.pumpAndSettle();

    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    expect(map.mapController!.camera.center.latitude, closeTo(10.77, .0001));
    expect(map.mapController!.camera.center.longitude, closeTo(106.70, .0001));
    expect(find.byKey(const ValueKey('device-pin-A')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('ordinary polling preserves the map area chosen by the user', (
    tester,
  ) async {
    phoneSize(tester, const Size(390, 844));
    List<Station> devices = [Station.fromJson(station('A', 'ESP32 A'))];
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return StationMap(
                stations: devices,
                loadTiles: false,
                onSelect: (_) {},
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    controller.move(const LatLng(11.2, 107.2), 10);
    await tester.pumpAndSettle();
    update(() => devices = [Station.fromJson(station('A', 'ESP32 A'))]);
    await tester.pumpAndSettle();
    expect(controller.camera.center.latitude, closeTo(11.2, .0001));
    expect(controller.camera.center.longitude, closeTo(107.2, .0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed initial request can be retried successfully', (
    tester,
  ) async {
    phoneSize(tester, const Size(390, 844));
    var fail = true;
    final api = ApiService(
      baseUrl: 'http://iot.test',
      client: MockClient((request) async {
        if (request.url.path == '/api/devices') {
          return fail
              ? respond({'error': 'MySQL chưa sẵn sàng'}, 503)
              : respond([station('ESP32_01', 'Trạm Bình Dương')]);
        }
        return respond([]);
      }),
    );
    addTearDown(api.close);
    await tester.pumpWidget(
      MyApp(api: api, autoRefresh: false, loadMapTiles: false),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('MySQL chưa sẵn sàng'), findsWidgets);
    fail = false;
    await tester.tap(find.text('Thử lại').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('MySQL chưa sẵn sàng'), findsNothing);
    expect(find.text('Trạm Bình Dương'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
