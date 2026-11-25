# Người xem và quản trị viên

- `/`: xem bản đồ, điểm đo, số liệu, lịch sử, dự báo và cảnh báo. Không cần đăng nhập, không có đăng ký tài khoản.
- `/admin`: đăng nhập quản trị rồi thêm, sửa tên/vị trí, tạm ngưng hoặc bật lại thiết bị. Nút Đăng xuất kết thúc phiên quản trị.
- Các API đọc vẫn công khai để website và app Flutter sử dụng. POST/PUT/DELETE thiết bị cần phiên admin và CSRF token; gọi trực tiếp API khi chưa đăng nhập trả 401. MQTT vẫn tiếp nhận dữ liệu của bo như trước.
- Flask còn kiểm tra tập trung mọi trang đã đăng ký dưới `/admin` (trừ trang đăng nhập) và mọi API ghi dưới `/api/`, kể cả route mới quên gắn decorator. API đọc GET/HEAD và yêu cầu OPTIONS vẫn giữ cách truy cập hiện có. `/admin/` cũng yêu cầu đăng nhập.

## Tạo hoặc đổi tài khoản

Từ thư mục `he_thong_nong_buc`:

```powershell
python tool/manage_admin.py --generate
```

Tên mặc định là `admin`; mật khẩu ngẫu nhiên được lưu cục bộ ở `backend/instance/ADMIN_CREDENTIALS.txt`. Cấu hình máy chủ chỉ lưu hash mật khẩu và khóa ký phiên tại `backend/instance/admin.json`. Cả thư mục đã được loại khỏi Git và nằm ngoài thư mục static.

Để tự đặt mật khẩu, chạy lệnh sau rồi nhập mật khẩu trong terminal (không hiện khi gõ):

```powershell
python tool/manage_admin.py --username admin --replace
```

Khởi động lại Flask sau khi tạo/đổi tài khoản. Đổi tài khoản cũng thay khóa ký, vô hiệu các phiên đăng nhập cũ. Có thể xóa `ADMIN_CREDENTIALS.txt` sau khi lưu mật khẩu; không xóa `admin.json` nếu muốn giữ tài khoản qua lần khởi động tiếp theo. Không có tài khoản/mật khẩu mặc định dùng chung; khi chưa cấu hình admin, các thao tác ghi bị khóa.

Phiên admin có hạn 8 giờ; mật khẩu được băm bằng Werkzeug. Đăng nhập và thao tác ghi có kiểm tra CSRF. Sau 10 lần đăng nhập sai từ một địa chỉ trong 15 phút, máy chủ tạm chặn đăng nhập từ địa chỉ đó. Bộ đếm nằm trong tiến trình hiện tại.

Trên máy đang chạy Flask, mở `http://127.0.0.1:5000/` hoặc `http://127.0.0.1:5000/admin`. Thiết bị khác dùng địa chỉ LAN của máy chủ. Bản triển khai này chưa đưa website lên Internet; khi triển khai Internet, dùng HTTPS, đặt `SESSION_COOKIE_SECURE=1` và giữ cấu hình admin riêng trên máy chủ.

## Kiểm tra

```powershell
python -m unittest backend.test_app backend.test_admin_auth
node tool/check_web_location.cjs
node tool/check_web_location.cjs --public
```

Test quyền truy cập dùng database giả; không thay đổi thiết bị thật. Kiểm tra JavaScript dùng DOM/Leaflet giả lập và snapshot MQTT cũ, kiểm tra riêng hai giao diện công khai/quản trị.

### Kiểm tra trình duyệt với Flask/MySQL thật

Khi Flask và MySQL đang chạy, có Chrome và thư viện Playwright:

```powershell
python tool/check_admin_browser.py
```

Script mở hai phiên Chrome ẩn danh độc lập, dùng tài khoản cục bộ trong `backend/instance/ADMIN_CREDENTIALS.txt`. Có thể chỉ định máy chủ bằng `--url` và tệp tài khoản bằng `--credentials`. Script không in mật khẩu, không thay API bằng dữ liệu giả. Nó đổi thử tên một trạm đang hoạt động qua form quản trị, chờ trang công khai tự cập nhật rồi khôi phục tên ban đầu, kể cả khi một bước xác minh thất bại. Chỉ chạy khi được phép sửa thử trạm.

Kết quả ngày 16/11/2026: **58 test backend đạt**, kiểm tra JavaScript cho cả hai giao diện đạt. Kiểm tra Chrome với Flask/MySQL thật đạt các bước:

- `/` mở ngay, tải bản đồ/danh sách trạm; menu desktop, menu điện thoại và chân trang không có liên kết đăng nhập, đăng ký hay quản trị.
- Sáu API đọc hiện có truy cập được khi chưa đăng nhập.
- `/admin` chuyển tới `/admin/login`; gọi trực tiếp API thêm/sửa/tạm ngưng trạm khi chưa đăng nhập trả 401.
- Đăng nhập bằng tài khoản admin thật thành công; ghi dữ liệu thiếu CSRF bị từ chối 403.
- Đổi tên trạm qua form quản trị thành công; phiên công khai riêng tự nhận tên mới qua polling. Tên ban đầu đã được khôi phục.
- Đăng xuất trở về `/`; API ghi sau đăng xuất trả 401.

Báo cáo máy đọc được: `build/admin-browser-review/result.json`. Ảnh kiểm tra desktop, điện thoại và hai trang sau khi cập nhật ở cùng thư mục. Dự báo hiện trả 422 do chưa đủ 12 giờ dữ liệu liên tiếp; kiểm tra quyền truy cập không thay đổi điều kiện dữ liệu của mô hình.
