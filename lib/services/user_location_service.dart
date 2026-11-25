import 'package:flutter/services.dart';
import 'package:latlong2/latlong.dart';
import 'location_platform_native.dart'
    if (dart.library.js_interop) 'location_platform_web.dart'
    as platform;

class UserPosition {
  const UserPosition(this.point, this.accuracy);
  final LatLng point;
  final double accuracy;
}

class LocationOutcome {
  const LocationOutcome(this.status, [this.position]);
  final String status;
  final UserPosition? position;

  String get message => switch (status) {
    'success' =>
      'Vị trí của bạn · Độ chính xác khoảng ${position!.accuracy.round()} m',
    'permission_denied' =>
      'Bạn chưa cấp quyền vị trí. Vẫn có thể nhập điểm đi thủ công.',
    'permission_denied_forever' =>
      'Quyền vị trí đã bị chặn. Mở cài đặt quyền hoặc nhập điểm đi thủ công.',
    'services_declined' || 'deferred' =>
      'Đã để sau. Bạn vẫn xem bản đồ và nhập điểm đi thủ công được.',
    'services_unavailable' =>
      'Chưa bật được vị trí bằng hệ thống. Kiểm tra cài đặt vị trí hoặc nhập điểm đi thủ công.',
    'timeout' =>
      'Chưa nhận được tọa độ. Bấm Định vị tôi để thử lại hoặc nhập điểm đi thủ công.',
    'insecure_context' =>
      'Trình duyệt cần HTTPS để lấy vị trí trên điện thoại. Bạn vẫn có thể nhập điểm đi thủ công.',
    'browser_unavailable' =>
      'Chưa lấy được vị trí từ thiết bị. Hãy bật Vị trí trong cài đặt điện thoại rồi bấm Định vị tôi, hoặc nhập điểm đi thủ công.',
    'interrupted' =>
      'Định vị đã dừng khi rời ứng dụng. Bấm Định vị tôi khi cần.',
    _ => 'Chưa lấy được vị trí. Bạn vẫn có thể nhập điểm đi thủ công.',
  };
}

class UserLocationService {
  static const channel = MethodChannel('heatwatch/location');
  Future<LocationOutcome> locate({bool automatic = false}) async {
    try {
      final data = await platform.locate(automatic: automatic);
      if (data?['status'] == 'success') {
        final lat = (data!['latitude'] as num).toDouble();
        final lon = (data['longitude'] as num).toDouble();
        final accuracy = (data['accuracy'] as num).toDouble();
        if (!lat.isFinite ||
            !lon.isFinite ||
            !accuracy.isFinite ||
            lat.abs() > 90 ||
            lon.abs() > 180 ||
            accuracy < 0) {
          return const LocationOutcome('unavailable');
        }
        return LocationOutcome(
          'success',
          UserPosition(LatLng(lat, lon), accuracy),
        );
      }
      return LocationOutcome(data?['status'] as String? ?? 'unavailable');
    } on MissingPluginException {
      return const LocationOutcome('unsupported');
    } on PlatformException {
      return const LocationOutcome('unavailable');
    }
  }

  Future<void> openSettings() => platform.openSettings();
}
