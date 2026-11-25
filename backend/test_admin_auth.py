import re
from pathlib import Path
from unittest import TestCase
from unittest.mock import MagicMock, patch

from werkzeug.security import generate_password_hash
from flask import Flask

from . import app as api
from . import admin_auth

PASSWORD = "test-admin-password-2026"
PASSWORD_HASH = generate_password_hash(PASSWORD)


class AdminAuthTests(TestCase):
    def test_application_uses_the_same_instance_directory_as_admin_setup(self):
        self.assertEqual(Path(api.app.instance_path), Path(api.__file__).resolve().parent / "instance")

    def setUp(self):
        config = patch.dict(api.app.config, TESTING=True, SECRET_KEY="auth-test-secret",
                            ADMIN_USER="owner", ADMIN_PASSWORD_HASH=PASSWORD_HASH)
        config.start()
        self.addCleanup(config.stop)
        admin_auth._attempts.clear()
        self.client = api.app.test_client()
        self.connection = MagicMock()
        self.cursor = self.connection.cursor.return_value.__enter__.return_value
        self.cursor.fetchall.return_value = []
        db = patch.object(api, "get_db_connection", return_value=self.connection)
        db.start()
        self.addCleanup(db.stop)

    def csrf(self):
        page = self.client.get("/admin/login")
        return re.search(r'name="csrf_token" value="([^"]+)"', page.get_data(as_text=True)).group(1)

    def login(self, password=PASSWORD):
        return self.client.post("/admin/login", data={"username": "owner", "password": password, "csrf_token": self.csrf()})

    def test_public_view_and_read_apis_without_account(self):
        page = self.client.get("/")
        self.assertEqual(page.status_code, 200)
        html = page.get_data(as_text=True)
        for control in ('id="devices"', 'id="device-dialog"', 'id="add-device"', 'id="admin-csrf"'):
            self.assertNotIn(control, html)
        self.assertNotIn('href="/admin/login"', html)
        self.assertNotIn('href="/admin"', html)
        for text in ("Đăng nhập", "Đăng ký", "Quản trị", "Đăng xuất"):
            self.assertNotIn(text, html)
        self.assertNotIn("Set-Cookie", page.headers)
        for path in ("/api/devices", "/api/sensor/history", "/api/alerts", "/api/health"):
            self.assertEqual(self.client.get(path).status_code, 200, path)
        self.assertNotIn(self.client.get("/api/sensor/latest").status_code, (401, 403))
        self.assertNotIn(self.client.get("/api/sensor/forecast").status_code, (401, 403))

    def test_anonymous_cannot_write_even_with_forged_role_headers(self):
        for method, path in (("post", "/api/devices"), ("put", "/api/devices/A"), ("delete", "/api/devices/A")):
            result = getattr(self.client, method)(path, json={"device_id": "A", "name": "A"},
                                                  headers={"X-Admin": "true", "X-CSRF-Token": "forged"})
            self.assertEqual(result.status_code, 401)
            self.assertEqual(result.json["code"], "admin_required")
        self.connection.cursor.assert_not_called()

    def test_admin_page_redirects_and_registration_does_not_exist(self):
        self.assertEqual(self.client.get("/admin").headers["Location"], "/admin/login")
        self.assertEqual(self.client.get("/admin/").headers["Location"], "/admin/login")
        self.assertEqual(self.client.get("/register").status_code, 404)
        self.assertEqual(self.client.get("/admin/register").status_code, 404)

    def test_non_admin_session_cannot_manage(self):
        with self.client.session_transaction() as auth_session:
            auth_session.update(user="viewer", role="admin", admin_user="viewer",
                                admin_tag="forged",
                                csrf_token="viewer-token")
        self.assertEqual(self.client.get("/admin").status_code, 302)
        self.assertEqual(self.client.put("/api/devices/A", json={"name": "Changed"},
                         headers={"X-CSRF-Token": "viewer-token"}).status_code, 401)
        self.connection.cursor.assert_not_called()

    def test_central_policy_protects_new_management_routes_without_decorators(self):
        isolated = Flask(__name__)
        admin_auth.init_admin_auth(isolated)
        isolated.config.update(TESTING=True, SECRET_KEY="isolated-secret", ADMIN_USER="owner",
                               ADMIN_PASSWORD_HASH=PASSWORD_HASH)
        isolated.add_url_rule("/admin/devices", "manage_devices", lambda: "private")
        isolated.add_url_rule("/api/locations", "write_location", lambda: "changed", methods=["PATCH"])
        isolated.add_url_rule("/api/locations", "read_locations", lambda: "public")
        client = isolated.test_client()
        self.assertEqual(client.get("/admin/devices").headers["Location"], "/admin/login")
        self.assertEqual(client.patch("/api/locations").status_code, 401)
        self.assertEqual(client.get("/api/locations").status_code, 200)
        with isolated.app_context():
            tag = admin_auth.credential_tag()
        with client.session_transaction() as auth_session:
            auth_session.update(admin_user="owner", admin_tag=tag, csrf_token="test-token")
        self.assertEqual(client.get("/admin/devices").status_code, 200)
        self.assertEqual(client.patch("/api/locations").status_code, 403)
        self.assertEqual(client.patch("/api/locations", headers={"X-CSRF-Token": "test-token"}).status_code, 200)

    def test_login_rotates_csrf_and_does_not_expose_hash_or_password(self):
        old_csrf = self.csrf()
        result = self.client.post("/admin/login", data={"username": "owner", "password": PASSWORD, "csrf_token": old_csrf})
        self.assertEqual(result.status_code, 302)
        self.assertEqual(result.headers["Location"], "/admin")
        cookie = result.headers["Set-Cookie"]
        self.assertIn("HttpOnly", cookie)
        self.assertIn("SameSite=Lax", cookie)
        with self.client.session_transaction() as auth_session:
            self.assertNotEqual(auth_session["csrf_token"], old_csrf)
            self.assertNotIn(PASSWORD_HASH, str(dict(auth_session)))
        html = self.client.get("/admin").get_data(as_text=True)
        self.assertIn('id="device-dialog"', html)
        self.assertIn('id="admin-csrf"', html)
        self.assertNotIn(PASSWORD, html)
        self.assertNotIn(PASSWORD_HASH, html)
        # The public route remains a read-only view even for the owner.
        self.assertNotIn('id="device-dialog"', self.client.get("/").get_data(as_text=True))

    def test_wrong_password_and_login_csrf_fail_closed(self):
        self.assertEqual(self.login("wrong").status_code, 401)
        self.assertEqual(self.client.get("/admin").status_code, 302)
        result = self.client.post("/admin/login", data={"username": "owner", "password": PASSWORD})
        self.assertEqual(result.status_code, 403)
        self.assertEqual(self.client.get("/admin").status_code, 302)

    def test_throttle_expires(self):
        with patch.object(admin_auth.time, "monotonic", return_value=1000):
            for _ in range(10):
                self.assertEqual(self.login("wrong").status_code, 401)
            result = self.login()
            self.assertEqual(result.status_code, 429)
            self.assertEqual(result.headers["Retry-After"], "900")
        with patch.object(admin_auth.time, "monotonic", return_value=1901):
            self.assertEqual(self.login().status_code, 302)
            self.assertEqual(self.client.get("/admin").status_code, 200)

    def test_all_mutations_require_csrf_and_valid_admin_can_manage(self):
        self.login()
        for method, path in (("post", "/api/devices"), ("put", "/api/devices/A"), ("delete", "/api/devices/A")):
            self.assertEqual(getattr(self.client, method)(path, json={}).status_code, 403)
            self.assertEqual(getattr(self.client, method)(path, json={}, headers={"X-CSRF-Token": "bad"}).status_code, 403)
        self.connection.cursor.assert_not_called()
        with self.client.session_transaction() as auth_session:
            token = auth_session["csrf_token"]
        headers = {"X-CSRF-Token": token}
        self.cursor.fetchone.return_value = None
        result = self.client.post("/api/devices", json={"device_id": "A", "name": "Test", "latitude": 10, "longitude": 106}, headers=headers)
        self.assertEqual(result.status_code, 201)
        self.cursor.fetchone.return_value = {"device_id": "A", "name": "Test", "enabled": 1}
        self.assertEqual(self.client.put("/api/devices/A", json={"name": "Updated"}, headers=headers).status_code, 200)
        self.assertEqual(self.client.delete("/api/devices/A", headers=headers).status_code, 200)

    def test_logout_requires_post_csrf_then_blocks_all_writes(self):
        self.login()
        self.assertEqual(self.client.get("/admin/logout").status_code, 405)
        self.assertEqual(self.client.post("/admin/logout").status_code, 403)
        with self.client.session_transaction() as auth_session:
            token = auth_session["csrf_token"]
        result = self.client.post("/admin/logout", data={"csrf_token": token})
        self.assertEqual(result.headers["Location"], "/")
        self.assertEqual(self.client.delete("/api/devices/A", headers={"X-CSRF-Token": token}).status_code, 401)

    def test_changing_credentials_invalidates_old_sessions(self):
        self.login()
        with patch.dict(api.app.config, ADMIN_PASSWORD_HASH="a-new-password-hash"):
            self.assertEqual(self.client.get("/admin").status_code, 302)
            self.assertEqual(self.client.delete("/api/devices/A").status_code, 401)

    def test_unconfigured_admin_fails_closed_but_public_page_stays_available(self):
        with patch.dict(api.app.config, ADMIN_PASSWORD_HASH=""):
            self.assertEqual(self.client.get("/").status_code, 200)
            self.assertEqual(self.client.get("/admin/login").status_code, 503)
            self.assertEqual(self.client.post("/api/devices", json={}).status_code, 401)

    def test_secure_cookie_setting_and_private_pages_not_cached(self):
        with patch.dict(api.app.config, SESSION_COOKIE_SECURE=True):
            result = self.client.get("/admin/login", base_url="https://localhost")
            self.assertIn("Secure", result.headers["Set-Cookie"])
        for path in ("/", "/admin/login", "/api/devices"):
            self.assertEqual(self.client.get(path).headers["Cache-Control"], "no-store")
