# Chạy HeatWatch trên web và điện thoại

## 1. Chạy máy chủ Flask

1. Mở **Laragon** và bật **MySQL**. Dự án trên máy này dùng database `iot_db` ở cổng `3307`.
2. Mở PowerShell trong thư mục `he_thong_nong_buc`.
3. Chạy các lệnh sau. Chỉ cần cài thư viện Python lần đầu hoặc khi đổi môi trường.

```powershell
python -m pip install -r backend/requirements.txt
python backend/app.py
```

Giữ cửa sổ PowerShell mở trong lúc dùng web và app. Nếu Flask đã chạy ở cổng 5000, dùng phiên đang chạy. Bạn có thể mở [trang kiểm tra máy chủ](http://127.0.0.1:5000/api/health) để xem trạng thái MySQL và MQTT.

| Cấu hình MySQL của backend | Giá trị mặc định trong mã |
| --- | --- |
| Máy chủ và cổng | `127.0.0.1:3307` |
| Database | `iot_db` |
| Tài khoản | `root` |
| Mật khẩu | `root`, nếu chưa ghi đè bằng `DB_PASSWORD` |

Nếu bạn đã đặt mật khẩu MySQL riêng trong Laragon, đặt `DB_PASSWORD` theo mật khẩu đó trước khi chạy Flask. Xem thêm [cấu hình Laragon](KET_NOI_LARAGON.md).

## 2. Mở web và đăng nhập quản trị

- **Web công khai** mở tại [127.0.0.1:5000](http://127.0.0.1:5000/), dùng trực tiếp.
- **Web quản trị** mở tại [127.0.0.1:5000/admin](http://127.0.0.1:5000/admin). Tên đăng nhập đã cấu hình là **`admin`**. Dùng mật khẩu quản trị đã đặt trước đó.
- Khi mở web từ điện thoại cùng Wi-Fi, dùng địa chỉ LAN của máy chạy Flask. Địa chỉ Wi-Fi lúc kiểm tra là [192.168.1.24:5000](http://192.168.1.24:5000/). Nếu mạng đổi IP, chạy `ipconfig` trên máy tính và lấy dòng **IPv4 Address** của Wi-Fi.

Mật khẩu quản trị hiện chỉ có bản băm trong cấu hình. Nếu đã quên, đặt mật khẩu mới bằng lệnh sau, nhập lại để xác nhận rồi khởi động lại Flask. Mật khẩu cần ít nhất 12 ký tự. Các phiên quản trị cũ sẽ hết hiệu lực.

```powershell
python tool/manage_admin.py --username admin --replace
```

Xem thêm [hướng dẫn quản trị](QUAN_TRI.md).

## 3. Cài app Android và kết nối

1. Chép file [`app-debug.apk`](build/app/outputs/flutter-apk/app-debug.apk) hiện có vào điện thoại Android, rồi mở file để cài. Nếu đang có sẵn `app-release.apk` từ lần đóng gói trước, bạn cũng có thể cài file đó.
2. Kết nối điện thoại và máy tính chạy Flask vào cùng Wi-Fi.
3. Mở **HeatWatch**, bấm biểu tượng **Kết nối máy chủ** ở góc trên bên phải. Nhập `http://192.168.1.24:5000` hoặc IP LAN hiện tại của máy tính, rồi bấm **Kết nối**. Trên Android Emulator, dùng `http://10.0.2.2:5000`.
4. App dùng trực tiếp. Mở **Bản đồ**, **Điểm đo** hoặc **Thời tiết** để kiểm tra dữ liệu. Ô địa chỉ máy chủ có hiệu lực trong phiên app hiện tại.

### Đóng gói lại APK từ mã nguồn

Từ thư mục `he_thong_nong_buc`, chạy:

```powershell
flutter pub get
powershell -NoProfile -ExecutionPolicy Bypass -File tool/check_flutter.ps1 -Task release-apk
```

Sau khi đóng gói thành công, file cài nằm ở `build/app/outputs/flutter-apk/app-release.apk`.
