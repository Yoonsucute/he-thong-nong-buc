# HeatWatch — Theo dõi và dự báo nóng bức

[Hướng dẫn chạy web, cài app Android và đăng nhập quản trị](HUONG_DAN_CHAY.md)

Website `/` dành cho người xem công khai, không cần đăng nhập/đăng ký. Quản trị viên đăng nhập tại `/admin` để thêm, sửa hoặc tạm ngưng thiết bị; các API quản lý được bảo vệ bằng phiên admin và CSRF. Cách tạo/đổi tài khoản: [QUAN_TRI.md](QUAN_TRI.md).

Hệ thống dùng chung một REST API Flask/MySQL cho website quản trị và ứng dụng Flutter. Dữ liệu cảm biến được nhận qua MQTT. Không tự điền số 0 hoặc dữ liệu mô phỏng khi mất kết nối.

## Chức năng theo yêu cầu đồ án

| Website · HTML/CSS/JavaScript/Bootstrap | Ứng dụng điện thoại · Flutter |
| --- | --- |
| Thêm, sửa tên/vị trí, tạm ngưng và bật lại thiết bị | Danh sách điểm đo, tìm theo tên hoặc mã thiết bị |
| Theo dõi số đo hiện tại, thời gian cập nhật và trạng thái kết nối | Xem nhiệt độ, độ ẩm, chỉ số nóng bức tại từng điểm |
| Lọc lịch sử theo thiết bị/thời gian, bảng, biểu đồ và xuất CSV | Bản đồ vị trí các điểm đo; chạm ghim để mở chi tiết |
| Biểu đồ và kết quả dự báo từng giờ trong 5 giờ tiếp theo | Mức cảnh báo, thời gian đo, lịch sử và dự báo từng trạm |
| Nhật ký cảnh báo từ các bản đo thực tế | Kết nối Flask qua REST API; đổi địa chỉ máy chủ trong ứng dụng |
| Thời tiết hiện tại từ Open-Meteo | Thời tiết hiện tại theo trạm hoặc vị trí của người xem |
| So sánh tuyến đường theo nóng bức, mưa, quãng đường và thời gian | Cùng API định tuyến, hiển thị nguy cơ và nguồn dữ liệu từng đoạn |

Hai giao diện dùng ảnh vệ tinh Esri không có nhãn địa danh in sẵn; giữ nhãn tiếng Việt Hoàng Sa và Trường Sa. Cần Internet để tải ảnh bản đồ và các thư viện CDN của website.

## 1. Máy chủ và website

Cần Python có phiên bản được TensorFlow hỗ trợ nếu muốn chạy mô hình, MySQL, Flutter SDK và Android SDK để biên dịch điện thoại.

Từ thư mục gốc dự án, cài các gói Python:

```powershell
python -m pip install -r backend/requirements.txt
```

Tạo database `iot_db` nếu chưa có. Cấu trúc tham khảo ở `backend/schema.sql`. Khi kết nối lần đầu, máy chủ tự thêm các bảng còn thiếu và đăng ký những thiết bị đã có trong `sensor_logs`; giữ nguyên lịch sử hiện có.

Đặt biến môi trường bằng PowerShell rồi chạy:

```powershell
$env:DB_HOST = 'localhost'
$env:DB_PORT = '3307'
$env:DB_NAME = 'iot_db'
$env:DB_USER = 'root'
$env:DB_PASSWORD = 'mat-khau-mysql-cua-ban'
$env:MQTT_ENABLED = '1'
$env:PORT = '5000'
python backend/app.py
```

Danh sách biến môi trường: `backend/.env.example`. Tệp này là mẫu tham khảo, không được tự nạp. Đặt `MQTT_ENABLED=0` khi chỉ cần xem dữ liệu đã lưu. Dừng máy chủ Flask cũ trước khi khởi động phiên bản mới trên cùng cổng. Xem [cấu hình MySQL Laragon](KET_NOI_LARAGON.md) cho máy đang dùng cổng 3307.

Mở website **http://127.0.0.1:5000/**. Mặc định API và website cùng máy chủ; không cần chạy Flutter Web để xem website Bootstrap. Website tự cập nhật mỗi 15 giây và giữ lựa chọn bộ lọc khi cập nhật.

Gói dữ liệu MQTT gửi tới topic cấu hình bằng `MQTT_TOPIC`:

```json
{
  "device_id": "ESP32_01",
  "temperature": 31.2,
  "humidity": 65,
  "location_pending": true
}
```

Tọa độ cấu hình thiết bị được ưu tiên trên bản đồ. Khi MQTT gửi tọa độ mới, máy chủ cập nhật vị trí thiết bị; tọa độ gốc của từng lần đo vẫn được giữ trong lịch sử. Tạm ngưng thiết bị không xóa lịch sử; mở **Sửa** để bật lại.

## 2. Chạy ứng dụng điện thoại

```powershell
flutter pub get
flutter run --dart-define=API_BASE_URL=http://192.168.1.10:5000
```

Thay `192.168.1.10` bằng IP LAN của máy tính chạy Flask. Điện thoại thật và máy tính cần cùng mạng, máy chủ Flask lắng nghe cổng 5000. Android Emulator mặc định dùng `http://10.0.2.2:5000`; iOS Simulator dùng `http://127.0.0.1:5000`.

Có thể chạm biểu tượng **Kết nối máy chủ** trên thanh trên cùng để đổi IP ngay trong ứng dụng. Địa chỉ nhập có hiệu lực trong phiên hiện tại; dùng `API_BASE_URL` để đặt mặc định khi biên dịch.

Ứng dụng mở thẳng mục **Bản đồ**, tự căn tới các thiết bị ESP32 có vị trí. Mỗi ghim hiển thị mã thiết bị; chạm ghim để xem dữ liệu của đúng ESP32 đó. Thiết bị mất tín hiệu vẫn giữ ghim màu xám tại vị trí đã lưu trong MySQL.

Ứng dụng có bốn mục **Điểm đo**, **Bản đồ**, **Cảnh báo** và **Thời tiết**. Kéo xuống để làm mới. Chọn điểm đo để xem chỉ số, thời gian cập nhật, lịch sử 24 giờ/7 ngày và dự báo của riêng điểm đó. Dữ liệu cũ được ghi chú khi thiết bị hoặc máy chủ mất kết nối. Số đo tự làm mới mỗi 15 giây; chi tiết trạm mỗi 30 giây.

Android đã có quyền Internet và kết nối HTTP cho máy chủ nội bộ. iOS đã có mô tả quyền mạng nội bộ; lần đầu chạy cần cho phép kết nối mạng nội bộ trên điện thoại. Việc biên dịch iOS cần macOS/Xcode.

## 3. Vị trí và ghim thiết bị ESP32

**Định vị tôi** hiển thị vị trí người xem bằng chấm xanh và vòng độ chính xác riêng. Website cần HTTPS hoặc localhost để xin quyền vị trí. Có thể nhập điểm đi thủ công khi thiếu quyền. Điểm đi được gửi khi bấm **Tìm đường**; mục **Thời tiết** gửi tọa độ làm tròn khi chọn **Dùng vị trí của tôi**.

Ghim biểu diễn **vị trí ESP32**, không dùng GPS của điện thoại đang xem ứng dụng. `device_id` là mã định danh ổn định của từng ESP32. Vị trí được lưu trong bảng `devices` của MySQL; app của những người dùng khác đọc cùng dữ liệu từ API.

- **ESP32 lắp cố định:** trên website quản trị, mở **Thiết bị & vị trí → Sửa** và nhập tọa độ thực nơi lắp đặt. ESP32 chỉ gửi nhiệt độ/độ ẩm vẫn có ghim tại vị trí đã lưu.
- **ESP32 di chuyển:** firmware lấy vị trí từ module (LBS trên A7680C hoặc GPS/GNSS nếu phần cứng hỗ trợ) và gửi cả `latitude`, `longitude` trong cùng bản tin MQTT. Máy chủ lưu cặp vị trí mới, ứng dụng đồng bộ mỗi 15 giây.
- Bản tin thiếu hoặc sai một tọa độ giữ nguyên vị trí trước đó, vẫn lưu số đo hợp lệ. Thiết bị chưa từng có vị trí hợp lệ được ghi là chưa có vị trí, không tự đặt ghim ở tọa độ mẫu.

Ví dụ MQTT trên là số đo chưa có vị trí. Khi module định vị thành công, firmware tự gửi cặp tọa độ thực cùng `location_source: "lbs"` hoặc `"gnss"`, `location_age_s` và `location_pending: false`; không thêm tọa độ mẫu vào firmware.

### ESP32 + SIMCom A7680C đang dùng trong đồ án

Mã hoàn chỉnh: [firmware/heatwatch_a7680/heatwatch_a7680.ino](firmware/heatwatch_a7680/heatwatch_a7680.ino), hướng dẫn ở [firmware/README.md](firmware/README.md). Giữ UART2 RX16/TX17, I2C21/22, SHT31 và OLED như mạch hiện tại.

Firmware bổ sung `DEVICE_ID=ESP32_01`, gọi `AT+CLBS=1` và chờ kết quả bất đồng bộ `+CLBS:`; chữ `OK` ban đầu chưa phải kết quả định vị. Chỉ gửi cặp tọa độ khi định vị thành công, theo đúng thứ tự vĩ độ/kinh độ của firmware modem. Phiên bản A76XX mới dùng vĩ độ trước; có công tắc cấu hình cho firmware cũ dùng thứ tự ngược, không tự suy đoán.

Gói MQTT có vị trí LBS bổ sung `location_source: "lbs"` và `location_age_s`. MySQL lưu thêm `location_source`, `location_updated_at` trong `devices` và `sensor_logs`; máy chủ tự thêm cột còn thiếu khi chạy. Dữ liệu cũ giữ nguồn chưa xác định/thời gian định vị chưa có, không được đổi thành GPS. App và website ghi rõ **vị trí ước lượng qua mạng 4G**, tách thời gian định vị khỏi thời gian đo cảm biến.

Mặc định lấy LBS mỗi 120 giây, sử dụng vị trí đã lấy tối đa 10 phút. Nếu LBS lỗi hoặc chưa có tọa độ, firmware vẫn gửi số đo hợp lệ và bỏ các trường tọa độ; MySQL giữ vị trí cũ. LBS phụ thuộc SIM, đăng ký mạng, PDP/APN và dịch vụ LBS của module tại nơi sử dụng; cần kiểm tra kết quả thực từ Serial Monitor trước khi coi vị trí trên bản đồ là vị trí được module xác nhận.

## 4. Dự báo và cảnh báo

LSTM nhận **12 giờ dữ liệu liên tiếp của cùng một thiết bị**, gộp trung bình theo giờ, rồi xuất 5 mốc giờ tiếp theo. Khi thiếu dữ liệu, thiếu tệp mô hình hoặc không tải được TensorFlow, API trả lỗi rõ ràng và giao diện hiển thị “Chưa có dự báo”.

Mô hình đi kèm được huấn luyện bằng dữ liệu mô phỏng trong `backend/ml/train_model.py`. Kết quả được gắn nhãn **mô hình thử nghiệm**; cần huấn luyện và đánh giá trên dữ liệu đo thực để sử dụng thực tế.

Ngưỡng đang dùng theo cấu hình đồ án: chỉ số nóng bức dưới 32 °C: “An toàn”; từ 32 °C: “Cảnh báo nóng”; từ 38 °C: “Cực kỳ nguy hiểm”. Trạng thái thiết bị đang hoạt động khi có bản đo trong 120 giây, có thể chỉnh bằng `DEVICE_ONLINE_SECONDS`.

Trên **Bản đồ**, mở **Tìm đường tránh nóng bức và hạn chế mưa**, chọn điểm đi, điểm đến, phương tiện và giờ khởi hành. Valhalla cung cấp tuyến; HeatWatch so sánh theo thời gian đi qua từng đoạn. Nguồn chỉ số nóng bức lần lượt là ESP32 có GPS và số đo còn mới trong bán kính 2 km, LSTM nếu đủ lịch sử và có dự báo tại giờ đi qua, rồi Open-Meteo. Open-Meteo cung cấp dự báo mưa. Đoạn thiếu dữ liệu có màu xám; tuyến ngắn nhất vẫn hiển thị khi chưa đủ dữ liệu để xếp hạng rủi ro.

## 5. Kiểm tra và đóng gói

```powershell
python -m unittest backend.test_app -v
flutter analyze
flutter test
flutter build apk --debug --dart-define=API_BASE_URL=http://192.168.1.10:5000
```

Flutter hiện tại có lỗi sinh mã test với dấu nháy đơn trong đường dẫn Windows như `Due'bass`. Script đi kèm dùng một ổ đĩa tạm trỏ tới cùng dự án, không di chuyển tệp và tự gỡ ổ sau khi chạy:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/check_flutter.ps1 -Task test
powershell -NoProfile -ExecutionPolicy Bypass -File tool/check_flutter.ps1 -Task apk
```

Script dùng đường dẫn Flutter đã cài tại `C:\sr\Flutter\flutter`; sửa `$flutterCommand` nếu SDK ở vị trí khác. APK debug ở `build/app/outputs/flutter-apk/app-debug.apk`; có thể đổi địa chỉ máy chủ trong app sau khi cài.

## API chính

| Phương thức | Đường dẫn | Chức năng |
| --- | --- | --- |
| GET | `/api/health` | Kiểm tra máy chủ/MySQL/MQTT |
| GET, POST | `/api/devices` | Danh sách và thêm thiết bị |
| PUT, DELETE | `/api/devices/<device_id>` | Sửa hoặc tạm ngưng thiết bị |
| GET | `/api/sensor/latest?device_id=...` | Bản đo gần nhất |
| GET | `/api/sensor/history?device_id=...&start=...&end=...&limit=200` | Lịch sử theo thời gian, thứ tự tăng dần |
| GET | `/api/sensor/forecast?device_id=...` | Dự báo 5 giờ riêng từng thiết bị |
| GET | `/api/alerts?device_id=...&limit=100` | Các bản đo vượt ngưỡng, mới nhất trước |
| GET | `/api/weather?point=lat,lon&current_only=1` | Thời tiết hiện tại và xác suất mưa trong khung giờ hiện tại từ Open-Meteo |
| GET | `/api/rain-route?start=lat,lon&end=lat,lon&vehicle=motorcycle` | So sánh tuyến và nguồn dữ liệu từng đoạn |

Thời gian API dùng ISO 8601 kèm múi giờ Việt Nam `+07:00`; bộ lọc chấp nhận cả UTC. Thư mục `lib/models`, `lib/services`, `lib/screens`, `lib/widgets` tách dữ liệu, REST API, màn hình và các thành phần giao diện.
