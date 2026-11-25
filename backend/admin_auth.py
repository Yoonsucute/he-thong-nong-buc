"""Single-owner admin login. Public read APIs do not require a session."""
from collections import OrderedDict
from datetime import timedelta
from functools import wraps
import hashlib
import json
import os
from pathlib import Path
import secrets
import threading
import time

from flask import abort, current_app, jsonify, redirect, render_template, request, session, url_for
from werkzeug.security import check_password_hash, generate_password_hash

_attempts = OrderedDict()
_attempt_lock = threading.Lock()
_dummy_hash = generate_password_hash(secrets.token_urlsafe(24))


def configured():
    return bool(current_app.secret_key and current_app.config.get("ADMIN_USER")
                and current_app.config.get("ADMIN_PASSWORD_HASH"))


def credential_tag():
    return hashlib.sha256((current_app.config.get("ADMIN_USER", "") + "\0" +
                           current_app.config.get("ADMIN_PASSWORD_HASH", "")).encode()).hexdigest()


def is_admin():
    return (configured() and session.get("admin_user") == current_app.config["ADMIN_USER"]
            and secrets.compare_digest(session.get("admin_tag", ""), credential_tag()))


def csrf_token():
    if "csrf_token" not in session:
        session["csrf_token"] = secrets.token_urlsafe(32)
    return session["csrf_token"]


def valid_csrf():
    value = request.headers.get("X-CSRF-Token") or request.form.get("csrf_token", "")
    expected = session.get("csrf_token", "")
    return bool(expected and value and secrets.compare_digest(value, expected))


def check_admin_access():
    if not is_admin():
        if request.path.startswith("/api/"):
            return jsonify(error="Cần đăng nhập quản trị để thực hiện thao tác này.", code="admin_required"), 401
        return redirect(url_for("admin_login"))
    if request.method not in ("GET", "HEAD", "OPTIONS") and not valid_csrf():
        return jsonify(error="Phiên xác nhận không hợp lệ. Tải lại trang quản trị rồi thử lại.", code="csrf_invalid"), 403
    return None


def admin_required(view):
    @wraps(view)
    def protected(*args, **kwargs):
        denied = check_admin_access()
        if denied is not None:
            return denied
        return view(*args, **kwargs)
    return protected


def init_admin_auth(app):
    settings_path = Path(app.instance_path) / "admin.json"
    settings = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
    app.config.update(
        SECRET_KEY=os.getenv("SECRET_KEY") or settings.get("secret_key"),
        ADMIN_USER=os.getenv("ADMIN_USER") or settings.get("username", ""),
        ADMIN_PASSWORD_HASH=os.getenv("ADMIN_PASSWORD_HASH") or settings.get("password_hash", ""),
        SESSION_COOKIE_HTTPONLY=True,
        SESSION_COOKIE_SAMESITE="Lax",
        SESSION_COOKIE_SECURE=os.getenv("SESSION_COOKIE_SECURE", "0") == "1",
        PERMANENT_SESSION_LIFETIME=timedelta(hours=8),
        SESSION_REFRESH_EACH_REQUEST=False,
        MAX_CONTENT_LENGTH=65536,
    )

    @app.context_processor
    def auth_context():
        return {"csrf_token": csrf_token}

    @app.before_request
    def protect_management():
        # Fail closed even when a new management view omits its decorator.
        admin_page = request.path == "/admin" or request.path.startswith("/admin/")
        api_write = request.path.startswith("/api/") and request.method not in ("GET", "HEAD", "OPTIONS")
        if (admin_page and request.endpoint not in (None, "admin_login")) or api_write:
            return check_admin_access()

    @app.after_request
    def auth_headers(response):
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "SAMEORIGIN"
        response.headers["Referrer-Policy"] = "same-origin"
        if request.path.startswith("/admin") or request.path == "/" or request.path.startswith("/api/"):
            response.headers["Cache-Control"] = "no-store"
        return response

    @app.route("/admin/login", methods=["GET", "POST"])
    def admin_login():
        if request.content_length and request.content_length > 8192:
            abort(413)
        if not configured():
            return render_template("admin_login.html", configured=False, error="Tài khoản quản trị chưa được cấu hình."), 503
        if is_admin():
            return redirect(url_for("admin_dashboard"))
        error, status = None, 200
        if request.method == "POST":
            if not valid_csrf():
                error, status = "Phiên đăng nhập đã hết hạn. Vui lòng thử lại.", 403
            else:
                now = time.monotonic()
                address = request.remote_addr or "unknown"
                # Reserve an attempt before password verification, including concurrent requests.
                with _attempt_lock:
                    for key, (_, started) in list(_attempts.items()):
                        if now - started >= 900:
                            del _attempts[key]
                    count, started = _attempts.get(address, (0, now))
                    blocked = count >= 10
                    _attempts[address] = (count + 1, started)
                    _attempts.move_to_end(address)
                    while len(_attempts) > 4096:
                        _attempts.popitem(last=False)
                if blocked:
                    error, status = "Đăng nhập sai quá nhiều lần. Vui lòng thử lại sau 15 phút.", 429
                else:
                    username = request.form.get("username", "")
                    password = request.form.get("password", "")
                    correct_user = secrets.compare_digest(username.encode(), current_app.config["ADMIN_USER"].encode())
                    password_hash = current_app.config["ADMIN_PASSWORD_HASH"] if correct_user else _dummy_hash
                    correct_password = len(password) <= 1024 and check_password_hash(password_hash, password)
                    if correct_user and correct_password:
                        with _attempt_lock:
                            _attempts.pop(address, None)
                        session.clear()
                        session.permanent = True
                        session["admin_user"] = username
                        session["admin_tag"] = credential_tag()
                        csrf_token()
                        return redirect(url_for("admin_dashboard"))
                    error, status = "Tên đăng nhập hoặc mật khẩu không đúng.", 401
        response = current_app.make_response((render_template("admin_login.html", configured=True, error=error), status))
        if status == 429:
            response.headers["Retry-After"] = "900"
        return response

    @app.get("/admin", strict_slashes=False)
    @admin_required
    def admin_dashboard():
        return render_template("index.html", admin_view=True)

    @app.post("/admin/logout")
    @admin_required
    def admin_logout():
        session.clear()
        return redirect(url_for("website"))
