import 'package:flutter/services.dart';

const _channel = MethodChannel('heatwatch/location');

Future<Map<String, dynamic>?> locate({required bool automatic}) => _channel
    .invokeMapMethod<String, dynamic>('locate', {'automatic': automatic});

Future<void> openSettings() => _channel.invokeMethod<void>('openAppSettings');
