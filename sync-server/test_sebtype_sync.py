#!/usr/bin/env python3
"""Tests for sebtype_sync.py (#12, #14): python3 -I sync-server/test_sebtype_sync.py

The server on a free local port with a made-up user, and the PC client syncing two made-up Rime
user dirs and a made-up Mozc dictionary through it."""

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
        for name in (
            "rime_ice.userdb.txt",
            "mozc_dictionary.txt",
            "userdictionary.json",
        ):
            self.call("PUT", f"/v1/files/dev-a/{name}", b"made up\n")
        files = json.loads(self.call("GET", "/v1/files")[1])["files"]
        self.assertEqual(
            [(f["device"], f["name"]) for f in files],
            [
                ("dev-a", "mozc_dictionary.txt"),
                ("dev-a", "rime_ice.userdb.txt"),
                ("dev-a", "userdictionary.json"),
            ],
        )
        self.assertEqual(
            self.call("GET", "/v1/files/dev-a/rime_ice.userdb.txt")[1], b"made up\n"
        )
        self.call(
            "DELETE", "/v1/files"
        )  # every device's files: learned words and dictionaries
        self.assertEqual(json.loads(self.call("GET", "/v1/files")[1])["files"], [])
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.call("GET", "/v1/files/dev-a/mozc_dictionary.txt")
        self.assertEqual(e.exception.code, 404)

    def test_only_synced_files_inside_the_users_folder(self):
        for path in (
            "/v1/files/dev-a/custom_phrase.txt",
            "/v1/files/dev-a/x.mozc_dictionary.txt",
            "/v1/files/../alice/x.userdb.txt",
            "/v1/files/dev-a/..%2Fx.userdb.txt",
            "/v1/files/.hidden/x.userdb.txt",
        ):
            with self.assertRaises(urllib.error.HTTPError, msg=path) as e:
                self.call("PUT", path, b"x")
            self.assertEqual(e.exception.code, 404, path)

    def test_crash_reports_go_to_their_own_folder(self):
        """A report lands in crashes/<user>/, apart from the learned words, and only under a report's name."""
        self.call("DELETE", "/v1/files")
        name = "crash-20261111-202304-0a1b2c.txt"
        self.assertEqual(
            self.call("PUT", f"/v1/crashes/{name}", b"made up trace\n")[0], 204
        )
        with open(os.path.join(self.data, "crashes", "alice", name), "rb") as f:
            self.assertEqual(f.read(), b"made up trace\n")
        self.assertEqual(json.loads(self.call("GET", "/v1/files")[1])["files"], [])
        for path in (
            "/v1/crashes/../x.txt",
            "/v1/crashes/crash-1.txt",
            f"/v1/crashes/sub/{name}",
            f"/v1/crashes/{name}.userdb.txt",
        ):
            with self.assertRaises(urllib.error.HTTPError, msg=path) as e:
                self.call("PUT", path, b"x")
            self.assertEqual(e.exception.code, 404, path)
        with self.assertRaises(urllib.error.HTTPError) as e:
            self.call("PUT", f"/v1/crashes/{name}", b"x" * (s.MAX_CRASH + 1))
        self.assertEqual(e.exception.code, 413)

    def rime_dirs(self, *devices):
        dirs = []
        for device in devices:
            d = tempfile.mkdtemp(dir=self.data)
            with open(os.path.join(d, "installation.yaml"), "w") as f:
                f.write(f'installation_id: "{device}"\nrime_version: 1.16.1\n')
            os.makedirs(os.path.join(d, "sync", device))
            with open(os.path.join(d, "sync", device, "rime_ice.userdb.txt"), "w") as f:
                f.write(f"made up word of {device}\n")
            dirs.append(d)
        return dirs

    def test_pc_client_syncs_two_devices(self):
        """Each device pushes only its own folder and pulls the other's."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        dirs = self.rime_dirs("pc-0001", "phone-0002")
        for d in dirs:
            device, sync_dir = s.rime_installation(d)
            self.assertEqual(s.push(client, device, sync_dir), 1)
            self.assertEqual(
                s.push(client, device, sync_dir), 0
            )  # unchanged: nothing sent
        device, sync_dir = s.rime_installation(dirs[0])
        self.assertEqual(s.pull(client, device, sync_dir), (1, 0))
        with open(os.path.join(sync_dir, "phone-0002", "rime_ice.userdb.txt")) as f:
            self.assertEqual(f.read(), "made up word of phone-0002\n")
        self.assertEqual(s.pull(client, device, sync_dir), (0, 0))

    def test_mozc_dictionary_syncs_and_a_deleted_word_stays_deleted(self):
        """A PC's Mozc words go up in Mozc's export format; another device's new words come into a
        dictionary of their own, and a word deleted on the PC doesn't come back."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        device, sync_dir = s.rime_installation(self.rime_dirs("pc-0003")[0])
        db = os.path.join(tempfile.mkdtemp(dir=self.data), "user_dictionary.db")

        def entry(reading, word, *fields):
            return s.pb_field(
                4, s.pb_field(1, reading) + s.pb_field(2, word) + b"".join(fields)
            )

        mine = (
            s.pb_field(1, 7)
            + s.pb_field(3, "ユーザー辞書 1")
            + entry(
                "もふりん", "モフリン堂", s.pb_field(5, 8), s.pb_field(4, "made up")
            )
        )
        mine += entry("けした", "消した語", s.pb_field(10, 1))  # removed in Mozc's tool
        mine += entry(
            "じどう", "自動語", s.pb_field(11, 1)
        )  # registered by Mozc itself
        off = s.pb_field(1, 9) + s.pb_field(2, 0) + entry("むこう", "無効語")
        with open(db, "wb") as f:
            f.write(s.pb_field(1, 1) + s.pb_field(2, mine) + s.pb_field(2, off))

        self.assertEqual(
            s.push(client, device, sync_dir, db), 2
        )  # with Rime's snapshot
        self.assertEqual(
            self.call("GET", "/v1/files/pc-0003/mozc_dictionary.txt")[1].decode(),
            "もふりん\tモフリン堂\t組織\tmade up\n",
        )

        phone = "ぷるもに\tプルモニ語\t名詞\nぴよぽん\tピヨポン丸\t品詞なし\n"
        self.call("PUT", "/v1/files/phone-0004/mozc_dictionary.txt", phone.encode())
        self.call("PUT", "/v1/files/phone-0004/userdictionary.json", b"[]")
        self.assertEqual(s.pull(client, device, sync_dir, db), (1, 2))
        with open(db, "rb") as f:
            words = s.mozc_words(f.read())
        self.assertIn(("ぴよぽん", "ピヨポン丸", 0, ""), words)
        self.assertIn(("ぷるもに", "プルモニ語", 1, ""), words)
        self.assertTrue(os.path.isfile(db + ".sebtype-backup"))

        # Deleted on the PC (its own dictionaries kept as they were), then the phone adds a word.
        with open(db, "wb") as f:
            f.write(s.pb_field(2, mine) + s.pb_field(2, off))
        phone += "ぐるみん\tグルミン\t人名\n"
        self.call("PUT", "/v1/files/phone-0004/mozc_dictionary.txt", phone.encode())
        self.assertEqual(s.pull(client, device, sync_dir, db), (1, 1))
        with open(db, "rb") as f:
            stored = f.read()
        self.assertEqual(
            sorted(w for _, w, _, _ in s.mozc_words(stored)), ["グルミン", "モフリン堂"]
        )
        self.assertTrue(stored.startswith(s.pb_field(2, mine) + s.pb_field(2, off)))


if __name__ == "__main__":
    unittest.main()
