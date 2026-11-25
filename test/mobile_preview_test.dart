import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:he_thong_nong_buc/main.dart';

import 'widget_test.dart' as fixtures;

const capturePreviews = bool.fromEnvironment('CAPTURE_PREVIEWS');

// These previews use the test-only fixture API. The application itself never
// substitutes sample data for a failed or missing sensor reading.
void main() {
  testWidgets('capture phone layout with test-only sample readings', (
    tester,
  ) async {
    fixtures.phoneSize(tester, const Size(390, 844));
    final api = fixtures.fixtureApi();
    addTearDown(api.close);

    // Widget tests otherwise render Ahem blocks, which conceal text layout.
    // Use a locally installed font for visual inspection on this workstation.
    await tester.runAsync(() async {
      final fontFile = File(r'C:\Windows\Fonts\segoeui.ttf');
      if (await fontFile.exists()) {
        final loader = FontLoader('Roboto');
        loader.addFont(
          Future<ByteData>.value(
            ByteData.sublistView(await fontFile.readAsBytes()),
          ),
        );
        await loader.load();
      }
      final iconFile = File(
        r'C:\sr\Flutter\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
      );
      if (await iconFile.exists()) {
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          Future<ByteData>.value(
            ByteData.sublistView(await iconFile.readAsBytes()),
          ),
        );
        await icons.load();
      }
    });

    const previewKey = ValueKey('mobile-preview-boundary');
    await tester.pumpWidget(
      RepaintBoundary(
        key: previewKey,
        child: MyApp(api: api, autoRefresh: false, loadMapTiles: false),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> capture(String name) async {
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(previewKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) throw StateError('Could not encode preview PNG.');
        final target = File('build/previews/$name.png');
        await target.parent.create(recursive: true);
        await target.writeAsBytes(bytes.buffer.asUint8List());
        image.dispose();
      });
    }

    await capture('mobile-map');
    await fixtures.showStationList(tester);
    await capture('mobile-points');
    await tester.ensureVisible(find.text('Trạm Bình Dương'));
    await tester.tap(find.text('Trạm Bình Dương'));
    await tester.pumpAndSettle();
    await capture('mobile-detail');
    await tester.ensureVisible(find.text('Dự báo 5 giờ tới'));
    await tester.pumpAndSettle();
    await capture('mobile-forecast');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Thời tiết'));
    await tester.pumpAndSettle();
    expect(find.text('Dự báo nóng bức 5 giờ tới'), findsOneWidget);
    await capture('mobile-weather');
    expect(tester.takeException(), isNull);
  }, skip: !capturePreviews);
}
