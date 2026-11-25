"""Create or rotate the single admin account from the local terminal."""
import argparse
import getpass
import json
from pathlib import Path
import secrets
import sys

from werkzeug.security import generate_password_hash


def main():
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description="Tạo/đổi tài khoản quản trị HeatWatch")
    parser.add_argument("--username", default="admin")
    parser.add_argument("--generate", action="store_true", help="Tạo mật khẩu ngẫu nhiên và lưu vào tệp cục bộ")
    parser.add_argument("--replace", action="store_true", help="Thay thế tài khoản đã có, đăng xuất các phiên cũ sau khi khởi động lại")
    args = parser.parse_args()
    if not args.username.strip() or len(args.username) > 100:
        parser.error("Tên đăng nhập cần từ 1 đến 100 ký tự.")
    instance = Path(__file__).resolve().parents[1] / "backend" / "instance"
    path = instance / "admin.json"
    if path.exists() and not args.replace:
        parser.error("Đã có tài khoản. Dùng --replace nếu muốn thay thế.")
    password = secrets.token_urlsafe(18) if args.generate else getpass.getpass("Mật khẩu admin (ít nhất 12 ký tự): ")
    if len(password) < 12 or len(password) > 1024:
        parser.error("Mật khẩu cần từ 12 đến 1024 ký tự.")
    if not args.generate and password != getpass.getpass("Nhập lại mật khẩu: "):
        parser.error("Hai mật khẩu không khớp.")
    instance.mkdir(parents=True, exist_ok=True)
    settings = {"username": args.username.strip(), "password_hash": generate_password_hash(password),
                "secret_key": secrets.token_hex(32)}
    path.write_text(json.dumps(settings, indent=2), encoding="utf-8")
    credentials = instance / "ADMIN_CREDENTIALS.txt"
    if args.generate:
        credentials.write_text(f"HeatWatch admin\nURL: http://127.0.0.1:5000/admin\nUsername: {settings['username']}\nPassword: {password}\n\nTệp này chỉ dành cho chủ dự án. Có thể xóa sau khi lưu mật khẩu.\n", encoding="utf-8")
        print("Đã tạo tài khoản. Thông tin đăng nhập ở backend/instance/ADMIN_CREDENTIALS.txt")
    elif credentials.exists():
        credentials.unlink()
    print("Khởi động lại Flask để áp dụng. Không chia sẻ thư mục backend/instance.")


if __name__ == "__main__":
    main()
