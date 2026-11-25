// Test entry point only. The production app still uses the Esri URL directly.
// Serve tool/check_ui.py --serve and adb reverse tcp:5056 tcp:5056 first.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:he_thong_nong_buc/main.dart';

void main() => runApp(MyApp(mapTileProvider: _LocalImagery()));

class _LocalImagery extends TileProvider {
  @override
  ImageProvider getImage(
    TileCoordinates coordinates,
    TileLayer options,
  ) => NetworkImage(
    'http://127.0.0.1:5056/test-tiles/${coordinates.z}/${coordinates.y}/${coordinates.x}',
  );
}
