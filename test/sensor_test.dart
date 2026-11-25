import 'package:flutter_test/flutter_test.dart';

import 'package:he_thong_nong_buc/models/sensor.dart';

void main() {
  test(
    'missing and nonfinite measurements remain unknown rather than zero',
    () {
      final reading = Reading.fromJson({
        'device_id': 'A',
        'temperature': null,
        'humidity': 'NaN',
        'heat_index': 'Infinity',
        'latitude': 'not a number',
      });
      expect(reading.temperature, isNull);
      expect(reading.humidity, isNull);
      expect(reading.heatIndex, isNull);
      expect(reading.latitude, isNull);
      expect(reading.level, -1);
      expect(measurement(reading.heatIndex), '—');
      expect(warningText(reading.level), 'Chưa có dữ liệu');
    },
  );

  test(
    'zero is a valid measurement distinct from a missing sensor reading',
    () {
      final reading = Reading.fromJson({
        'temperature': 0,
        'humidity': '0',
        'heat_index': 0,
      });
      expect(measurement(reading.temperature), '0.0 °C');
      expect(measurement(reading.humidity, '%'), '0.0 %');
      expect(reading.level, 0);
    },
  );

  test('classifies project warning boundaries consistently', () {
    expect(warningLevel(31.9), 0);
    expect(warningLevel(32), 1);
    expect(warningLevel(37.9), 1);
    expect(warningLevel(38), 2);
    expect(warningLevel(null), -1);
  });

  test('does not create map pins from invalid coordinates', () {
    final bad = Station.fromJson({
      'device_id': 'A',
      'latitude': 91,
      'longitude': 107,
    });
    final missing = Station.fromJson({'device_id': 'B'});
    final zero = Station.fromJson({
      'device_id': 'Z',
      'latitude': 0,
      'longitude': 0,
    });
    final valid = Station.fromJson({
      'device_id': 'C',
      'latitude': '10.77',
      'longitude': '106.70',
    });
    expect(bad.hasLocation, isFalse);
    expect(missing.hasLocation, isFalse);
    expect(zero.hasLocation, isFalse);
    expect(valid.hasLocation, isTrue);
  });

  test('keeps the last GPS station pin when the module loses its fix', () {
    final station = Station.fromJson({
      'device_id': 'ESP32_01',
      'latitude': 10.77,
      'longitude': 106.70,
      'location_source': 'gps',
      'location_status': 'last_known',
      'gps_valid': false,
      'satellites': 0,
    });
    expect(station.hasLocation, isTrue);
    expect(
      station.locationDescription,
      contains('Vị trí gần nhất · GPS ATGM336H'),
    );
    expect(station.locationDescription, contains('Chưa bắt được GPS'));
    final waiting = Station.fromJson({
      'device_id': 'ESP32_02',
      'location_status': 'unavailable',
      'gps_valid': false,
    });
    expect(waiting.hasLocation, isFalse);
    expect(waiting.locationDescription, 'Chưa bắt được GPS');
  });

  test('parses the server timezone and preserves missing timestamps', () {
    final time = parseTime('2026-10-29T11:15:00+07:00');
    expect(time!.toUtc(), DateTime.utc(2026, 10, 29, 4, 15));
    expect(parseTime(null), isNull);
    expect(parseTime('broken'), isNull);
    expect(displayTime(null), 'Chưa có thời gian cập nhật');
  });

  test(
    'uses one complete coordinate pair rather than mixing two locations',
    () {
      final partial = Station.fromJson({
        'device_id': 'A',
        'latitude': 11.2,
        'longitude': null,
        'latest': {'latitude': 10.77, 'longitude': 106.70},
      });
      expect(partial.mapLatitude, 10.77);
      expect(partial.mapLongitude, 106.70);
      final missingPair = Station.fromJson({
        'device_id': 'B',
        'latitude': 11.2,
        'latest': {'longitude': 106.70},
      });
      expect(missingPair.hasLocation, isFalse);
    },
  );

  test(
    'falls back to a valid saved reading when configured coordinates are invalid',
    () {
      final device = Station.fromJson({
        'device_id': 'A',
        'latitude': 91,
        'longitude': 106.7,
        'location_source': 'manual',
        'location_updated_at': '2026-10-29T10:30:00+07:00',
        'latest': {
          'latitude': 10.77,
          'longitude': 106.70,
          'location_source': 'lbs',
          'location_updated_at': '2026-10-29T10:00:00+07:00',
        },
      });
      expect(device.hasLocation, isTrue);
      expect(device.mapLatitude, 10.77);
      expect(device.mapLongitude, 106.70);
      expect(device.locationSource, 'lbs');
      expect(device.locationUpdatedAt!.toUtc(), DateTime.utc(2026, 10, 29, 3));
      final untimedFallback = Station.fromJson({
        'device_id': 'B',
        'latitude': 91,
        'longitude': 106.7,
        'location_source': 'manual',
        'location_updated_at': '2026-10-29T10:30:00+07:00',
        'latest': {'latitude': 10.77, 'longitude': 106.70},
      });
      expect(untimedFallback.locationSource, 'unknown');
      expect(untimedFallback.locationUpdatedAt, isNull);
    },
  );

  test(
    'LBS location remains approximate when a later sensor reading arrives',
    () {
      final device = Station.fromJson({
        'device_id': 'ESP32_LBS',
        'latitude': 10.77,
        'longitude': 106.70,
        'location_source': 'lbs',
        'location_updated_at': '2026-10-29T10:00:00+07:00',
        'last_seen': '2026-10-29T10:05:00+07:00',
        'latest': {
          'device_id': 'ESP32_LBS',
          'heat_index': 34,
          'created_at': '2026-10-29T10:05:00+07:00',
        },
      });
      expect(device.locationSource, 'lbs');
      expect(
        device.locationDescription,
        contains('Vị trí ước lượng qua mạng 4G'),
      );
      expect(device.locationUpdatedAt!.toUtc(), DateTime.utc(2026, 10, 29, 3));
      expect(
        device.latest!.createdAt!.difference(device.locationUpdatedAt!),
        const Duration(minutes: 5),
      );
    },
  );

  test('offline LBS fix keeps its coordinates and original update time', () {
    final device = Station.fromJson({
      'device_id': 'ESP32_LBS',
      'is_online': false,
      'latitude': 10.77,
      'longitude': 106.70,
      'location_source': 'lbs',
      'location_updated_at': '2026-10-29T09:10:00+07:00',
    });
    expect(device.online, isFalse);
    expect(device.hasLocation, isTrue);
    expect(device.locationSource, 'lbs');
    expect(device.locationDescription, isNot(contains('GPS')));
    expect(
      device.locationUpdatedAt!.toUtc(),
      DateTime.utc(2026, 10, 29, 2, 10),
    );
  });

  test('legacy and unknown location sources never claim to be GPS', () {
    for (final json in [
      {'device_id': 'A', 'latitude': 10.77, 'longitude': 106.70},
      {
        'device_id': 'B',
        'latitude': 10.77,
        'longitude': 106.70,
        'location_source': 'unsupported',
        'location_updated_at': 'not-a-time',
      },
    ]) {
      final device = Station.fromJson(json);
      expect(device.locationDescription, contains('Vị trí đã lưu'));
      expect(device.locationUpdatedAt, isNull);
    }
  });

  test(
    'history preserves the location fix time independently from measurement time',
    () {
      final row = Reading.fromJson({
        'device_id': 'ESP32_LBS',
        'heat_index': 34,
        'created_at': '2026-10-29T10:05:00+07:00',
        'location_source': 'lbs',
        'location_updated_at': '2026-10-29T10:00:00+07:00',
      });
      expect(row.locationSource, 'lbs');
      expect(row.locationUpdatedAt!.toUtc(), DateTime.utc(2026, 10, 29, 3));
      expect(row.createdAt!.toUtc(), DateTime.utc(2026, 10, 29, 3, 5));
    },
  );
}
