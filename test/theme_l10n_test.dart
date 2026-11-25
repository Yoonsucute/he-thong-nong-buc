import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:he_thong_nong_buc/l10n/app_strings.dart';
import 'package:he_thong_nong_buc/main.dart';
import 'package:he_thong_nong_buc/theme/app_theme.dart';

import 'widget_test.dart' as fixtures;

void main() {
  testWidgets(
    'toggles between Light Mode and Dark Mode across tabs with no overflow',
    (tester) async {
      fixtures.phoneSize(tester, const Size(320, 700));
      final api = fixtures.fixtureApi(
        devices: [
          fixtures.station('ESP32_01', 'Trạm Bình Dương'),
          fixtures.station('ESP32_02', 'Trạm Thủ Đức')..['is_online'] = false,
        ],
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MyApp(
          api: api,
          autoRefresh: false,
          loadMapTiles: false,
          initialThemeMode: ThemeMode.light,
        ),
      );
      await tester.pumpAndSettle();

      BuildContext scaffoldContext() =>
          tester.element(find.byType(NavigationBar));

      expect(Theme.of(scaffoldContext()).brightness, Brightness.light);
      expect(
        HeatWatchColors.of(scaffoldContext()).cardSurface,
        HeatWatchColors.light.cardSurface,
      );

      // Toggle to Dark Mode via AppBar theme button.
      await tester.tap(find.byTooltip('Giao diện Sáng / Tối'));
      await tester.pumpAndSettle();

      expect(Theme.of(scaffoldContext()).brightness, Brightness.dark);
      expect(
        HeatWatchColors.of(scaffoldContext()).cardSurface,
        HeatWatchColors.dark.cardSurface,
      );

      // Navigate through all tabs and open detail screen in Dark Mode on narrow 320px phone.
      await tester.tap(find.text('Điểm đo').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cảnh báo').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Thời tiết').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Điểm đo').last);
      await tester.pumpAndSettle();

      final stationTarget = find.text('Trạm Bình Dương');
      await tester.ensureVisible(stationTarget);
      await tester.pumpAndSettle();
      await tester.tap(stationTarget);
      await tester.pumpAndSettle();
      expect(find.text('Dự báo 5 giờ tới'), findsOneWidget);
      expect(find.text('Lịch sử đo'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'switches between Vietnamese and English and filters station list',
    (tester) async {
      fixtures.phoneSize(tester, const Size(390, 844));
      final offlineSafe = fixtures.station('ESP32_SAFE', 'Trạm An Toàn')
        ..['is_online'] = false
        ..['latest'] = {
          'device_id': 'ESP32_SAFE',
          'temperature': 26.0,
          'humidity': 60.0,
          'heat_index': 27.0,
          'created_at': '2026-10-29T11:00:00+07:00',
        };
      final api = fixtures.fixtureApi(
        devices: [
          fixtures.station('ESP32_HOT', 'Trạm Nắng Nóng'),
          offlineSafe,
        ],
      );
      addTearDown(api.close);

      await tester.pumpWidget(
        MyApp(
          api: api,
          autoRefresh: false,
          loadMapTiles: false,
          initialLanguage: AppLanguage.vi,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('VI'), findsOneWidget);
      expect(find.text('Bản đồ điểm đo'), findsOneWidget);

      // Toggle to English.
      await tester.tap(find.text('VI'));
      await tester.pumpAndSettle();

      expect(find.text('EN'), findsOneWidget);
      expect(find.text('Station Map'), findsOneWidget);
      expect(find.text('Stations'), findsOneWidget);
      expect(find.text('Alerts'), findsOneWidget);
      expect(find.text('Weather'), findsOneWidget);

      // Open Stations tab and test filter chips in English.
      await tester.tap(find.text('Stations'));
      await tester.pumpAndSettle();
      expect(find.text('Trạm Nắng Nóng'), findsOneWidget);
      expect(find.text('Trạm An Toàn'), findsOneWidget);

      await tester.tap(find.text('Online'));
      await tester.pumpAndSettle();
      expect(find.text('Trạm Nắng Nóng'), findsOneWidget);
      expect(find.text('Trạm An Toàn'), findsNothing);

      await tester.tap(find.text('All'));
      await tester.pumpAndSettle();
      expect(find.text('Trạm An Toàn'), findsOneWidget);

      // Open StationDetailScreen in English.
      final detailTarget = find.text('Trạm Nắng Nóng');
      await tester.ensureVisible(detailTarget);
      await tester.pumpAndSettle();
      await tester.tap(detailTarget);
      await tester.pumpAndSettle();
      expect(find.text('5-Hour Heat Forecast'), findsOneWidget);
      expect(find.text('Measurement History'), findsOneWidget);

      // Verify Alerts and Weather tabs render cleanly in English.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Alerts').last);
      await tester.pumpAndSettle();
      expect(find.text('Heat Alerts'), findsOneWidget);
      await tester.tap(find.text('Weather'));
      await tester.pumpAndSettle();
      expect(find.text('Regional Weather'), findsOneWidget);
      expect(find.text('Current Weather from Open-Meteo'), findsOneWidget);

      expect(tester.takeException(), isNull);
    },
  );
}
