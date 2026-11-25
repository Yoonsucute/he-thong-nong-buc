import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:he_thong_nong_buc/services/user_location_service.dart';
import 'package:latlong2/latlong.dart';

@JS('navigator.geolocation.getCurrentPosition')
external JSFunction get _getPosition;
@JS('navigator.geolocation.getCurrentPosition')
external set _getPosition(JSFunction value);

void main() {
  test('web uses device geolocation with fresh precise fix and handles denial/timeout', () async {
    final original = _getPosition;
    addTearDown(() => _getPosition = original);
    var calls = 0;
    var errorCode = 0;
    _getPosition = ((JSFunction success, JSFunction error, JSObject options) {
      calls++;
      expect(options.getProperty<JSBoolean>('enableHighAccuracy'.toJS).toDart, isTrue);
      expect(options.getProperty<JSNumber>('maximumAge'.toJS).toDartInt, 0);
      expect(options.getProperty<JSNumber>('timeout'.toJS).toDartInt, 20000);
      if (errorCode == 0) {
        success.callAsFunction(null, {'coords': {'latitude': 10.76, 'longitude': 106.68, 'accuracy': 7}}.jsify());
      } else {
        error.callAsFunction(null, {'code': errorCode}.jsify());
      }
    }).toJS;
    final service = UserLocationService();
    final fix = await service.locate(automatic: true);
    expect(fix.position!.point, const LatLng(10.76, 106.68));
    expect(fix.position!.accuracy, 7);
    errorCode = 1;
    expect((await service.locate()).status, 'permission_denied');
    errorCode = 2;
    expect((await service.locate()).status, 'browser_unavailable');
    errorCode = 3;
    expect((await service.locate()).status, 'timeout');
    expect(calls, 4);
  });
}
