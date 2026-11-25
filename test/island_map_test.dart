import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:he_thong_nong_buc/models/sensor.dart';
import 'package:he_thong_nong_buc/widgets/station_map.dart';

const regions = {
  'Hoàng Sa': LatLng(16.5414, 111.6853),
  'Trường Sa': LatLng(8.6444, 111.9192),
};
const capture = bool.fromEnvironment('CAPTURE_ISLAND_MAPS');

class CachedImagery extends TileProvider {
  CachedImagery(this.tiles);
  final Map<String, Uint8List> tiles;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(
        tiles['${coordinates.z}/${coordinates.x}/${coordinates.y}'] ??
            TileProvider.transparentImage,
      );
}

void main() {
  testWidgets(
    'Vietnamese labels follow map pan/zoom and never block a device pin',
    (tester) async {
      tester.view.physicalSize = const Size(600, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final entry in regions.entries) {
        String? selected;
        final station = Station.fromJson({
          'device_id': 'TEST_PIN',
          'name': 'TEST_PIN',
          'is_online': true,
          'latitude': entry.value.latitude,
          'longitude': entry.value.longitude,
          'location_source': 'lbs',
          'location_updated_at': DateTime.now().toIso8601String(),
        });
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: StationMap(
                key: ValueKey(entry.key),
                stations: [station],
                loadTiles: false,
                onSelect: (station) => selected = station.id,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        for (final zoom in [3.0, 5.0, 8.0, 11.0, 15.0, 19.0]) {
          controller.move(entry.value, zoom);
          await tester.pumpAndSettle();
          final labels = tester
              .widgetList<MarkerLayer>(find.byType(MarkerLayer))
              .first
              .markers;
          expect(
            labels.map((m) => (m.point.latitude, m.point.longitude)),
            contains((entry.value.latitude, entry.value.longitude)),
          );
          expect(find.text(entry.key), findsOneWidget);
          expect(find.textContaining('QĐ.'), findsNothing);
        }
        controller.move(entry.value, 8);
        await tester.pumpAndSettle();
        await tester.drag(find.byType(FlutterMap), const Offset(40, -25));
        await tester.pumpAndSettle();
        expect(controller.camera.center, isNot(entry.value));
        expect(find.text(entry.key), findsOneWidget);
        controller.move(entry.value, 8);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('device-pin-TEST_PIN')));
        expect(selected, 'TEST_PIN');
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets(
    'capture real imagery and Vietnamese labels at both island groups',
    (tester) async {
      tester.view.physicalSize = const Size(600, 500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final tiles = <String, Uint8List>{};
      await tester.runAsync(() async {
        final font = FontLoader('Roboto');
        font.addFont(
          Future.value(
            ByteData.sublistView(
              await File(r'C:\Windows\Fonts\segoeui.ttf').readAsBytes(),
            ),
          ),
        );
        await font.load();
        final icons = FontLoader('MaterialIcons');
        icons.addFont(
          Future.value(
            ByteData.sublistView(
              await File(
                r'C:\sr\Flutter\flutter\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf',
              ).readAsBytes(),
            ),
          ),
        );
        await icons.load();
        final root = Directory('build/map-review/tiles');
        for (final file in root.listSync(recursive: true).whereType<File>()) {
          final key = file.path
              .substring(root.path.length + 1)
              .replaceAll('\\', '/')
              .replaceAll('.jpg', '');
          tiles[key] = await file.readAsBytes();
        }
      });
      expect(
        tiles,
        isNotEmpty,
        reason: 'Run python tool/prepare_map_tiles.py first',
      );
      const boundaryKey = ValueKey('island-preview');
      for (final entry in regions.entries) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RepaintBoundary(
                key: boundaryKey,
                child: ColoredBox(
                  color: Colors.white,
                  child: StationMap(
                    key: ValueKey(entry.key),
                    stations: const [],
                    onSelect: (_) {},
                    tileProvider: CachedImagery(tiles),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final controller = tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .mapController!;
        for (final zoom in [3, 5, 8, 11, 15, 19]) {
          controller.move(entry.value, zoom.toDouble());
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 100));
          });
          await tester.pumpAndSettle();
          expect(find.text(entry.key), findsOneWidget);
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(boundaryKey),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final region = entry.key == 'Hoàng Sa' ? 'hoang-sa' : 'truong-sa';
            await File(
              'build/map-review/flutter-$region-z$zoom.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
          expect(tester.takeException(), isNull);
        }
      }
    },
    skip: !capture,
  );
}
