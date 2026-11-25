import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

// One fix per request, kept in memory only. Browser permissions own the prompt;
// websites cannot launch Android's native location settings resolution dialog.
Future<Map<String, dynamic>?> locate({required bool automatic}) async {
  if (!web.window.isSecureContext) return {'status': 'insecure_context'};
  final result = Completer<Map<String, dynamic>>();
  void complete(Map<String, dynamic> data) {
    if (!result.isCompleted) result.complete(data);
  }

  try {
    web.window.navigator.geolocation.getCurrentPosition(
      ((web.GeolocationPosition fix) {
        complete({
          'status': 'success',
          'latitude': fix.coords.latitude,
          'longitude': fix.coords.longitude,
          'accuracy': fix.coords.accuracy,
        });
      }).toJS,
      ((web.GeolocationPositionError error) {
        complete({
          'status': switch (error.code) {
            1 => 'permission_denied',
            3 => 'timeout',
            _ => 'browser_unavailable',
          },
        });
      }).toJS,
      web.PositionOptions(
        enableHighAccuracy: true,
        maximumAge: 0,
        timeout: 20000,
      ),
    );
  } catch (_) {
    return {'status': 'browser_unavailable'};
  }
  return result.future;
}

// Browser permissions must be changed through its site settings UI.
Future<void> openSettings() async {}
