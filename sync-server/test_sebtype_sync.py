#!/usr/bin/env python3
"""Tests for sebtype_sync.py (#12): python3 -I sync-server/test_sebtype_sync.py

The server on a free local port with a made-up user, and the PC client syncing two made-up Rime
user dirs through it."""

import base64
import http.server
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sebtype_sync as s


class Server(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        cls.data = cls.tmp.name
        s.save_users(cls.data, {"alice": s.hash_password("made-up-pass")})
        s.Handler.data = cls.data
        s.Handler.log_message = lambda *a: None
        cls.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), s.Handler)
        cls.url = f"http://127.0.0.1:{cls.httpd.server_port}"
        threading.Thread(target=cls.httpd.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.tmp.cleanup()

    def call(self, method, path, body=None, password="made-up-pass"):
        req = urllib.request.Request(self.url + path, data=body, method=method)
        req.add_header(
            "Authorization",
            "Basic " + base64.b64encode(f"alice:{password}".encode()).decode(),
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            return r.status, r.read()

    def test_password_is_stored_hashed(self):
        with open(os.path.join(self.data, "users.json")) as f:
            stored = f.read()
        self.assertNotIn("made-up-pass", stored)
        self.assertTrue(s.check_password("made-up-pass", json.loads(stored)["alice"]))

    def test_wrong_password_is_refused(self):
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.call("GET", "/v1/files", password="wrong")
        self.assertEqual(e.exception.code, 401)

    def test_put_list_get_delete(self):
        self.call("DELETE", "/v1/files")
        self.call("PUT", "/v1/files/dev-a/rime_ice.userdb.txt", b"made up\n")
        files = json.loads(self.call("GET", "/v1/files")[1])["files"]
        self.assertEqual(
            [(f["device"], f["name"]) for f in files],
            [("dev-a", "rime_ice.userdb.txt")],
        )
        self.assertEqual(
            self.call("GET", "/v1/files/dev-a/rime_ice.userdb.txt")[1], b"made up\n"
        )
        self.call("DELETE", "/v1/files")
        self.assertEqual(json.loads(self.call("GET", "/v1/files")[1])["files"], [])

    def test_only_userdb_snapshots_inside_the_users_folder(self):
        for path in (
            "/v1/files/dev-a/custom_phrase.txt",
            "/v1/files/../alice/x.userdb.txt",
            "/v1/files/dev-a/..%2Fx.userdb.txt",
            "/v1/files/.hidden/x.userdb.txt",
        ):
            with self.assertRaises(urllib.error.HTTPError, msg=path) as e:
                self.call("PUT", path, b"x")
            self.assertEqual(e.exception.code, 404, path)

    def test_pc_client_syncs_two_devices(self):
        """Each device pushes only its own folder and pulls the other's."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        dirs = []
        for device in ("pc-0001", "phone-0002"):
            d = tempfile.mkdtemp(dir=self.data)
            with open(os.path.join(d, "installation.yaml"), "w") as f:
                f.write(f'installation_id: "{device}"\nrime_version: 1.16.1\n')
            os.makedirs(os.path.join(d, "sync", device))
            with open(os.path.join(d, "sync", device, "rime_ice.userdb.txt"), "w") as f:
                f.write(f"made up word of {device}\n")
            dirs.append(d)
        for d in dirs:
            device, sync_dir = s.rime_installation(d)
            self.assertEqual(s.push(client, device, sync_dir), 1)
            self.assertEqual(
                s.push(client, device, sync_dir), 0
            )  # unchanged: nothing sent
        device, sync_dir = s.rime_installation(dirs[0])
        self.assertEqual(s.pull(client, device, sync_dir), 1)
        with open(os.path.join(sync_dir, "phone-0002", "rime_ice.userdb.txt")) as f:
            self.assertEqual(f.read(), "made up word of phone-0002\n")
        self.assertEqual(s.pull(client, device, sync_dir), 0)


if __name__ == "__main__":
    unittest.main()
