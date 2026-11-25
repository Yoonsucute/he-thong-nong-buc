# Kết nối HeatWatch với MySQL Laragon

Đã chuyển ngày 14/11/2026:

| Mục | Giá trị |
| --- | --- |
| MySQL | Laragon MySQL 8.4.3 |
| Host | `127.0.0.1` |
| Cổng MySQL | `3307` |
| Database | `iot_db` |
| Tài khoản | `root`, mật khẩu đã đặt theo yêu cầu người dùng |
| Website / REST API | `http://127.0.0.1:5000/` |

Laragon dùng cổng 3307 do dịch vụ MySQL 8.0 riêng đang chiếm 3306. Cổng MySQL X của Laragon là 33070. Cấu hình nằm ở `C:\laragon\bin\mysql\mysql-8.4.3-winx64\my.ini`; có bản sao `my.ini.heatwatch-before-3307.bak` trước khi sửa. Không cần dừng MySQL 8.0 để dùng kết nối mới.

Backend mặc định dùng host/cổng ở trên. Biến môi trường `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` vẫn có thể ghi đè cấu hình. Không tự nạp `.env`; `.env.example` chỉ là mẫu. Khi chạy từ terminal từng đặt `DB_PORT=3306`, cần đặt lại 3307.

Đã lưu thêm `[mysql]` với `Port=3307`, `Version=mysql-8.4.3-winx64` trong `C:\laragon\usr\laragon.ini`; bản sao cấu hình cũ là `laragon.ini.heatwatch-before-3307.bak`. Laragon đang mở có thể cần mở lại để nạp thiết lập mới. Đã xác minh kết nối database thực, chưa thử thao tác Start/Stop từ giao diện Laragon sau khi mở lại.

## Dữ liệu đã chuyển

Đã sao lưu rồi sao chép database hiện có từ MySQL 8.0 sang Laragon. Tại thời điểm chuyển:

- `devices`: 1 bản ghi.
- `sensor_logs`: 333 bản ghi.
- Đã đối chiếu số lượng và SHA-256 của toàn bộ bản ghi theo khóa chính, hai bên giống nhau. Database nguồn vẫn được giữ nguyên.

Bản sao SQL: `build/backups/iot_db_before_laragon_20261114_222240.sql`. Báo cáo đối chiếu: `build/backups/laragon_migration.json`. Các tệp này chứa dữ liệu dự án, không phải dữ liệu minh họa của bộ kiểm tra giao diện.

## Cách chạy

Khởi động MySQL Laragon tại cổng 3307. Trong thư mục `he_thong_nong_buc`, chạy:

```powershell
$env:DB_HOST = '127.0.0.1'
$env:DB_PORT = '3307'
$env:DB_NAME = 'iot_db'
$env:DB_USER = 'root'
python backend/app.py
```

Backend sử dụng mật khẩu mặc định hiện có của dự án nếu chưa đặt `DB_PASSWORD`; nếu cần ghi đè, đặt riêng trong môi trường chạy. Mở `http://127.0.0.1:5000/`. `/api/health` kiểm tra API/MySQL và kết nối MQTT. App Flutter tiếp tục gọi REST API trên cổng 5000; cổng 3307 dành cho kết nối database của backend.

## Kết quả sau khi chuyển

Đã khởi động lại Flask với cấu hình Laragon, kiểm tra website HTTP 200, `/api/health` trả `status: ok` và `mqtt_connected: true`, `/api/devices` đọc được 1 thiết bị. Truy vấn từ chính cấu hình backend xác nhận MySQL 8.4.3, port 3307, basedir thuộc `C:\laragon\bin\mysql\mysql-8.4.3-winx64\`, database `iot_db`, 333 bản đo. Bộ 44 test backend hiện có vẫn qua.
