import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:he_thong_nong_buc/main.dart';
import 'package:he_thong_nong_buc/services/api_service.dart';
import 'package:he_thong_nong_buc/services/user_location_service.dart';
import 'package:he_thong_nong_buc/widgets/rain_route_panel.dart';
import 'package:he_thong_nong_buc/widgets/station_map.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';

import 'widget_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(UserLocationService.channel, null),
  );

  test(
    'platform bridge requests only foreground one-shot flow and validates fix',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(UserLocationService.channel, (
        call,
      ) async {
        calls.add(call);
        return {
          'status': 'success',
          'latitude': 10.76,
          'longitude': 106.68,
          'accuracy': 75.0,
        };
      });
      final fix = await UserLocationService().locate(automatic: true);
      expect(fix.position!.point, const LatLng(10.76, 106.68));
      expect(fix.position!.accuracy, 75);
      expect(calls.single.method, 'locate');
      expect(calls.single.arguments, {'automatic': true});
      messenger.setMockMethodCallHandler(
        UserLocationService.channel,
        (_) async => {
          'status': 'success',
          'latitude': 91,
          'longitude': 106,
          'accuracy': 0,
        },
      );
      expect((await UserLocationService().locate()).position, isNull);
    },
  );

  testWidgets(
    'startup tries once; resume and station polling do not repeat settings prompt',
    (tester) async {
      var calls = 0;
      messenger.setMockMethodCallHandler(UserLocationService.channel, (
        _,
      ) async {
        calls++;
        return {'status': 'services_declined'};
      });
      final api = fixtures.fixtureApi();
      addTearDown(api.close);
      await tester.pumpWidget(MyApp(api: api, loadMapTiles: false));
      await tester.pumpAndSettle();
      expect(calls, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 16));
      await tester.pumpAndSettle();
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'blue marker and metric accuracy circle are distinct from station pins',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StationMap(
              stations: const [],
              onSelect: (_) {},
              loadTiles: false,
              userPosition: const UserPosition(LatLng(10.76, 106.68), 75),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('user-location-dot')), findsOneWidget);
      expect(find.text('Vị trí của bạn'), findsOneWidget);
      final circle = tester
          .widget<CircleLayer>(find.byType(CircleLayer))
          .circles
          .single;
      expect(circle.radius, 75);
      expect(circle.useRadiusInMeter, isTrue);
      expect(circle.point, const LatLng(10.76, 106.68));
    },
  );

  testWidgets(
    'location origin remains local and editable until Find is pressed',
    (tester) async {
      fixtures.phoneSize(tester, const Size(390, 844));
      final requests = <Uri>[];
      final api = ApiService(
        baseUrl: 'http://native.test',
        client: MockClient((request) async {
          requests.add(request.url);
          return fixtures.respond({
            'routes': [
              {
                'id': 'route-1',
                'distance_km': 5,
                'duration_seconds': 600,
                'weather_complete': true,
                'heat_complete': true,
                'max_heat_index': 39,
                'heat_risk': 'high',
                'max_rain_probability': 42,
                'heat_source_percent': {
                  'esp32': 100,
                  'lstm': 0,
                  'open_meteo': 0,
                },
                'geometry': [
                  [10.78, 106.7],
                  [10.8, 106.75],
                ],
                'segments': [
                  {
                    'start_index': 0,
                    'end_index': 1,
                    'heat_source': 'esp32',
                    'heat_index': 39,
                    'station_name': 'Trạm Sân trường',
                    'passed_at': '2026-11-21T15:00:00+07:00',
                    'risk': 'high',
                    'probability_percent': 42,
                  },
                ],
              },
            ],
            'recommended_route_id': 'route-1',
            'shortest_route_id': 'route-1',
            'lowest_risk_route_id': 'route-1',
            'reasons': {'recommended': 'Cân bằng điểm rủi ro và thời gian.'},
            'warnings': [],
          });
        }),
      );
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RainRoutePanel(
                api: api,
                onPlan: (_) {},
                onUseLocation: () async =>
                    const UserPosition(LatLng(10.76, 106.68), 40),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Tìm đường tránh nóng bức và hạn chế mưa'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dùng vị trí của tôi'));
      await tester.pumpAndSettle();
      final start = find.byKey(const ValueKey('route-start'));
      expect(
        tester.widget<TextField>(start).controller!.text,
        'Vị trí của tôi',
      );
      expect(requests, isEmpty);
      await tester.enterText(start, '10.78,106.7');
      await tester.enterText(
        find.byKey(const ValueKey('route-end')),
        '10.8,106.75',
      );
      await tester.ensureVisible(find.text('Tìm đường'));
      await tester.tap(find.text('Tìm đường'));
      await tester.pumpAndSettle();
      expect(requests, hasLength(1));
      expect(requests.single.path, '/api/rain-route');
      expect(requests.single.queryParameters['start'], '10.78,106.7');
      expect(requests.single.queryParameters.containsKey('accuracy'), isFalse);
      expect(find.text('Tuyến phù hợp nhất'), findsOneWidget);
      expect(find.text('Tuyến ngắn nhất'), findsOneWidget);
      expect(find.text('Tuyến ít nguy cơ nóng bức và mưa'), findsOneWidget);
      expect(
        find.textContaining('Nóng bức Cao · Đỉnh 39.0 °C'),
        findsNWidgets(3),
      );
      expect(
        find.textContaining('Xác suất mưa cao nhất 42%'),
        findsNWidgets(3),
      );
      final sources = find.text('Nguồn dữ liệu từng đoạn của tuyến đang chọn');
      await tester.ensureVisible(sources);
      await tester.tap(sources);
      await tester.pumpAndSettle();
      expect(find.textContaining('ESP32 + SHT31'), findsOneWidget);
      expect(find.textContaining('Trạm Sân trường'), findsOneWidget);
    },
  );

  testWidgets('late location does not replace manually changed origin', (
    tester,
  ) async {
    final location = Completer<UserPosition?>();
    final api = fixtures.fixtureApi();
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: RainRoutePanel(
              api: api,
              onPlan: (_) {},
              onUseLocation: () => location.future,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Tìm đường tránh nóng bức và hạn chế mưa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dùng vị trí của tôi'));
    await tester.enterText(
      find.byKey(const ValueKey('route-start')),
      '10.78,106.7',
    );
    location.complete(const UserPosition(LatLng(10.76, 106.68), 40));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const ValueKey('route-start')))
          .controller!
          .text,
      '10.78,106.7',
    );
  });

  testWidgets(
    'automatic fixes default origin, refresh it, and preserve manual edits',
    (tester) async {
      final requests = <Uri>[];
      final api = ApiService(
        baseUrl: 'http://native.test',
        client: MockClient((request) async {
          requests.add(request.url);
          return http.Response('{"routes":[],"warnings":[]}', 200);
        }),
      );
      addTearDown(api.close);
      final origin = ValueNotifier<UserPosition?>(null);
      addTearDown(origin.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ValueListenableBuilder<UserPosition?>(
                valueListenable: origin,
                builder: (_, fix, _) => RainRoutePanel(
                  api: api,
                  defaultOrigin: fix,
                  onPlan: (_) {},
                  onUseLocation: () async => origin.value,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Tìm đường tránh nóng bức và hạn chế mưa'));
      await tester.pumpAndSettle();
      final start = find.byKey(const ValueKey('route-start'));
      String value() => tester.widget<TextField>(start).controller!.text;
      expect(value(), isEmpty);
      origin.value = const UserPosition(LatLng(10.76, 106.68), 40);
      await tester.pumpAndSettle();
      expect(value(), 'Vị trí của tôi');
      expect(requests, isEmpty);
      origin.value = const UserPosition(LatLng(10.77, 106.69), 5);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('route-end')),
        '10.8,106.75',
      );
      await tester.ensureVisible(find.text('Tìm đường'));
      await tester.tap(find.text('Tìm đường'));
      await tester.pumpAndSettle();
      expect(requests.single.queryParameters['start'], '10.77,106.69');
      await tester.enterText(start, '10.78,106.7');
      origin.value = const UserPosition(LatLng(10.79, 106.71), 3);
      await tester.pumpAndSettle();
      expect(value(), '10.78,106.7');
      await tester.enterText(start, '');
      origin.value = const UserPosition(LatLng(10.8, 106.72), 3);
      await tester.pumpAndSettle();
      expect(value(), isEmpty);
      expect(requests, hasLength(1));
    },
  );
}
