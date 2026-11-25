import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:he_thong_nong_buc/main.dart';
import 'package:he_thong_nong_buc/services/api_service.dart';
import 'package:he_thong_nong_buc/services/user_location_service.dart';
import 'package:http/testing.dart';

import 'widget_test.dart' as fixtures;

void main() {
  for (final size in [const Size(320, 800), const Size(1100, 850)]) {
    testWidgets(
      'weather keeps ESP32 and opt-in GPS separate at ${size.width}px',
      (tester) async {
        fixtures.phoneSize(tester, size);
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(UserLocationService.channel, (
          MethodCall call,
        ) async {
          return {
            'status': 'success',
            'latitude': 10.76432,
            'longitude': 106.68321,
            'accuracy': 30,
          };
        });
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            UserLocationService.channel,
            null,
          ),
        );

        final points = <String>[];
        final forecastStations = <String>[];
        var weatherFails = false;
        final api = ApiService(
          baseUrl: 'http://iot.test',
          client: MockClient((request) async {
            switch (request.url.path) {
              case '/api/devices':
                return fixtures.respond([
                  fixtures.station('ESP32_01', 'Trạm đo A'),
                  fixtures.station('ESP32_02', 'Trạm đo B'),
                ]);
              case '/api/weather':
                points.add(request.url.queryParameters['point']!);
                expect(request.url.queryParameters['current_only'], '1');
                if (weatherFails) {
                  return fixtures.respond({
                    'error': 'Open-Meteo chưa phản hồi',
                  }, 503);
                }
                return fixtures.respond(fixtures.mockWeather());
              case '/api/sensor/forecast':
                final id = request.url.queryParameters['device_id']!;
                forecastStations.add(id);
                if (id == 'ESP32_02') {
                  return fixtures.respond({
                    'error': 'Cần đủ 12 giờ liên tiếp',
                  }, 422);
                }
                return fixtures.respond(fixtures.mockForecast(id));
              default:
                return fixtures.respond([]);
            }
          }),
        );
        addTearDown(api.close);
        await tester.pumpWidget(
          MyApp(api: api, autoRefresh: false, loadMapTiles: false),
        );
        await tester.pumpAndSettle();
        expect(points, isEmpty);
        await tester.tap(find.text('Thời tiết'));
        await tester.pumpAndSettle();
        expect(points, ['10.77,106.70']);
        expect(find.text('Thời tiết hiện tại từ Open-Meteo'), findsOneWidget);
        expect(find.text('29.0 °C'), findsOneWidget);
        expect(find.text('Khả năng mưa đến 15:00'), findsOneWidget);
        expect(find.text('Dự báo nóng bức 5 giờ tới'), findsOneWidget);
        expect(forecastStations, ['ESP32_01']);
        expect(find.text('37.0 °C'), findsOneWidget);
        expect(find.text('28.5 °C'), findsNothing);
        await tester.tap(find.text('Dùng vị trí của tôi'));
        await tester.pumpAndSettle();
        expect(points.last, '10.76,106.68');
        expect(find.text('Khu vực của bạn'), findsOneWidget);
        expect(forecastStations, ['ESP32_01']);

        weatherFails = true;
        await tester.tap(find.text('Làm mới thời tiết'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('Đang hiển thị lần tải gần nhất'),
          findsOneWidget,
        );
        expect(find.text('37.0 °C'), findsOneWidget);
        weatherFails = false;
        await tester.tap(find.text('Trạm đo A').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Trạm đo B').last);
        await tester.pumpAndSettle();
        expect(forecastStations.last, 'ESP32_02');
        expect(find.textContaining('Cần đủ 12 giờ liên tiếp'), findsOneWidget);
        expect(find.text('37.0 °C'), findsNothing);
        expect(find.text('29.0 °C'), findsOneWidget);
        await tester.tap(find.text('Điểm đo'));
        await tester.pumpAndSettle();
        expect(find.text('35.1 °C'), findsWidgets);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
