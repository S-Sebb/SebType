#!/usr/bin/env python3
"""Tests for sebtype_sync.py (#12, #14): python3 -I sync-server/test_sebtype_sync.py

The server on a free local port with a made-up user, and the PC client syncing two made-up Rime
user dirs and a made-up Mozc dictionary through it."""

import base64
import http.server
import json
import os
import subprocess
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
        self.assertEqual(s.pull(client, device, sync_dir), (1, 0, 0, 0))
        with open(os.path.join(sync_dir, "phone-0002", "rime_ice.userdb.txt")) as f:
            self.assertEqual(f.read(), "made up word of phone-0002\n")
        self.assertEqual(s.pull(client, device, sync_dir), (0, 0, 0, 0))

    def test_command_line_reads_the_password_from_stdin(self):
        """The Configurator's way (#180): the password on stdin, a refused login as exit code 3, and
        delete clearing the server."""
        self.call("PUT", "/v1/files/dev-b/rime_ice.userdb.txt", b"made up\n")
        rime_dir = self.rime_dirs("pc-0005")[0]

        def run(command, password, *extra):
            return subprocess.run(
                [sys.executable, "-I", s.__file__, command, "--server", self.url]
                + ["--user", "alice", "--password-stdin", *extra],
                input=password + "\n",
                capture_output=True,
                text=True,
                timeout=60,
                check=False,
            )

        r = run("push", "made-up-pass", "--rime-dir", rime_dir)
        self.assertEqual(
            (r.returncode, r.stdout), (0, "push: 2 file(s)\n"), r.stderr
        )  # with its (empty) Chinese words
        self.assertEqual(run("pull", "wrong", "--rime-dir", rime_dir).returncode, 3)
        self.assertEqual(run("delete", "made-up-pass").returncode, 0)
        self.assertEqual(json.loads(self.call("GET", "/v1/files")[1])["files"], [])

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
        self.assertEqual(s.pull(client, device, sync_dir, db), (1, 2, 0, 0))
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
        self.assertEqual(s.pull(client, device, sync_dir, db), (1, 1, 0, 0))
        with open(db, "rb") as f:
            stored = f.read()
        self.assertEqual(
            sorted(w for _, w, _, _ in s.mozc_words(stored)), ["グルミン", "モフリン堂"]
        )
        self.assertTrue(stored.startswith(s.pb_field(2, mine) + s.pb_field(2, off)))

    def test_learned_conversions_sync_as_each_devices_record(self):
        """#409: a PC's record of the conversions picked in Mozc goes up as it is, only when it changed;
        another device's comes down next to it, for Mozc to learn; a server from before #409, which
        keeps no record, still syncs the rest; one larger than Mozc takes in isn't downloaded."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        device, sync_dir = s.rime_installation(self.rime_dirs("pc-0009")[0])
        mozc = tempfile.mkdtemp(dir=self.data)
        db = os.path.join(mozc, "user_dictionary.db")
        mine = "# SebType mozc_learned 1\nもふしゃ\t模符社\t100\n".encode()
        with open(os.path.join(mozc, s.LEARNED_FILE), "wb") as f:
            f.write(mine)
        self.assertEqual(
            s.push(client, device, sync_dir, db), 3
        )  # with Rime's and Mozc's
        self.assertEqual(
            self.call("GET", "/v1/files/pc-0009/mozc_learned.txt")[1], mine
        )
        self.assertEqual(
            s.push(client, device, sync_dir, db), 0
        )  # unchanged: nothing sent

        phone = "# SebType mozc_learned 1\nぷるしゃ\t普留社\t90\n".encode()
        self.call("PUT", "/v1/files/phone-0010/mozc_learned.txt", phone)
        self.assertEqual(s.pull(client, device, sync_dir), (0, 0, 0, 0))  # no Mozc here
        self.assertEqual(s.pull(client, device, sync_dir, db), (1, 0, 0, 1))
        with open(os.path.join(mozc, "mozc_learned", "phone-0010.txt"), "rb") as f:
            self.assertEqual(f.read(), phone)
        self.assertEqual(s.pull(client, device, sync_dir, db), (0, 0, 0, 0))
        # One past what Mozc takes in isn't downloaded at all.
        big = b"# SebType mozc_learned 1\n" + b"x" * s.MAX_LEARNED
        self.call("PUT", "/v1/files/phone-0011/mozc_learned.txt", big)
        self.assertEqual(s.pull(client, device, sync_dir, db), (0, 0, 0, 0))
        self.assertFalse(
            os.path.exists(os.path.join(mozc, "mozc_learned", "phone-0011.txt"))
        )

        with open(os.path.join(mozc, s.LEARNED_FILE), "ab") as f:
            f.write("もふしゃ\t模府社\t200\n".encode())
        synced, s.synced = (
            s.synced,
            lambda name: name != s.LEARNED_FILE and synced(name),
        )
        try:
            self.assertEqual(s.push(client, device, sync_dir, db), 0)
        finally:
            s.synced = synced
        self.assertEqual(
            self.call("GET", "/v1/files/pc-0009/mozc_learned.txt")[1], mine
        )

    def test_deletions_and_edits_sync_between_two_pcs(self):
        """#273: a word added on one PC reaches the other in SebType's dictionary (My words), its
        deletion deletes it there, and adding it again brings it back."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        pcs = []
        for d in self.rime_dirs("pc-a", "pc-b"):
            device, sync_dir = s.rime_installation(d)
            pcs.append((device, sync_dir, os.path.join(d, "user_dictionary.db")))

        def edit(pc, add=(), remove=()):
            db = s.read_mozc(pc[2]) or b""
            s.write_file(pc[2], s.mozc_add(s.mozc_remove(db, set(remove)), list(add)))

        def sync(pc):
            s.pull(client, pc[0], pc[1], pc[2])
            s.push(client, pc[0], pc[1], pc[2])
            with open(pc[2], "rb") as f:
                return sorted(w for _, w, _, _ in s.mozc_words(f.read()))

        a, b = pcs
        edit(a, add=[("ぷにょ", "プニョ島", 9)])
        edit(b, add=[("もちょ", "モチョ", 1)])
        sync(a), sync(b)
        self.assertEqual(sync(a), ["プニョ島", "モチョ"])
        self.assertEqual(sync(b), ["プニョ島", "モチョ"])
        with open(b[2], "rb") as f:
            self.assertIn(s.DICTIONARY.encode(), f.read())  # where My words reads it

        edit(a, remove=[("もちょ", "モチョ")])
        sync(a)
        self.assertEqual(sync(b), ["プニョ島"], "deleted on a, so on b too")
        self.assertEqual(sync(a), ["プニョ島"], "and b's file doesn't bring it back")

        edit(b, add=[("もちょ", "モチョ", 5)])
        sync(b)
        self.assertEqual(sync(a), ["プニョ島", "モチョ"], "added again on b")
        with open(a[2], "rb") as f:
            self.assertIn(("もちょ", "モチョ", 5, ""), s.mozc_words(f.read()))

    def test_newest_change_wins(self):
        """Delete on one device and add again or edit on another, and one word edited on two: each
        device ends with the newest change, whichever order the files arrive in."""
        word = s.Entry("ぴぴ", "ピピ丸", 1, time=10)
        start = {word.key: word}

        def device(change, now):
            if change == "delete":
                return s.stamp(start, [], now)
            return s.stamp(start, [("ぴぴ", "ピピ丸", change, "")], now)

        for first, second, winner in (
            (
                "delete",
                5,
                s.Entry("ぴぴ", "ピピ丸", 5, time=30),
            ),  # edited after the delete
            (
                5,
                "delete",
                s.Entry("ぴぴ", "ピピ丸", s.NOUN, "", 30, True),
            ),  # deleted after the edit
            (5, 9, s.Entry("ぴぴ", "ピピ丸", 9, time=30)),  # the later edit
        ):
            one, two = device(first, 20), device(second, 30)
            for own, other in ((one, two), (two, one)):
                own = dict(own)
                s.merge(own, s.format_entries(other), s.format_entries(start))
                self.assertEqual(own[word.key], winner, (first, second))
        first = s.stamp(None, [("ぴぴ", "ピピ丸", 1, "")], 20)
        gone = {word.key: s.Entry("ぴぴ", "ピピ丸", 1, "", 20, True)}
        self.assertEqual(
            s.merge(gone, s.format_entries(first), None),
            [],
            "a first sync dates nothing",
        )
        tie = {word.key: s.Entry("ぴぴ", "ピピ丸", 1, time=20)}
        self.assertEqual(
            len(s.merge(gone, s.format_entries(tie), None)), 1, "an addition wins a tie"
        )

    def take_in(self, db, own, *files, now=100):
        """Another device's files taken in one after another, each with the one before as its old copy."""
        old = None
        for new in files:
            s.mozc_take_in(db, own, new.encode(), old, now)
            old = new.encode()
        with open(db, "rb") as f:
            return s.mozc_words(f.read())

    def test_a_deletion_of_a_word_this_pc_lacks_is_kept(self):
        """A PC that never had a word keeps another device's deletion of it, so an older addition
        arriving later from a third device doesn't bring it back."""
        folder = tempfile.mkdtemp(dir=self.data)
        db, own = (
            os.path.join(folder, "user_dictionary.db"),
            os.path.join(folder, "own.txt"),
        )
        s.write_file(db, s.mozc_add(b"", [("もふ", "モフ", 1)]))
        s.own_mozc(db, own, 1)
        s.mozc_take_in(db, own, "#-\tぴぴ\tピピ\t\t\t20\n".encode(), None, 30)
        words = self.take_in(db, own, "ぴぴ\tピピ\t名詞\t\t10\n", now=40)
        self.assertEqual([w for _, w, _, _ in words], ["モフ"])

    def test_an_edit_keeps_the_words_comment(self):
        folder = tempfile.mkdtemp(dir=self.data)
        db, own = (
            os.path.join(folder, "user_dictionary.db"),
            os.path.join(folder, "own.txt"),
        )
        entry = s.pb_field(1, "もふ") + s.pb_field(2, "モフ") + s.pb_field(5, 1)
        storage = s.pb_field(3, s.DICTIONARY) + s.pb_field(
            4, entry + s.pb_field(4, "made up")
        )
        s.write_file(db, s.pb_field(2, storage))
        s.own_mozc(db, own, 1)
        words = self.take_in(db, own, "もふ\tモフ\t人名\t\t50\n")
        self.assertEqual(words, [("もふ", "モフ", 5, "made up")])

    def test_a_change_after_one_dated_in_the_future_still_wins(self):
        """Another device's clock ran ahead: a change made here after taking in its word is dated
        after that word's change, so it wins everywhere."""
        ahead = {("ぴぴ", "ピピ"): s.Entry("ぴぴ", "ピピ", 1, time=1000)}
        self.assertEqual(s.stamp(ahead, [], 50)[("ぴぴ", "ピピ")].time, 1001)
        edited = s.stamp(ahead, [("ぴぴ", "ピピ", 5, "")], 50)
        self.assertEqual(edited[("ぴぴ", "ピピ")].time, 1001)
        self.assertEqual(
            s.stamp(ahead, [("ぴぴ", "ピピ", 1, "")], 50), ahead, "unchanged"
        )

    def test_chinese_my_words_sync_between_two_pcs(self):
        """#272: My words in custom_phrase.txt, after rime-ice's own phrases, sync by the Japanese
        rules: an addition reaches the other PC, a deletion deletes it there, and adding it again
        brings it back; rime-ice's phrases stay as they are."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        pcs = [(d, *s.rime_installation(d)) for d in self.rime_dirs("zh-a", "zh-b")]
        shipped = "# rime-ice made up\n你好\tnihao\t1\n"
        for d, _, _ in pcs:
            with open(os.path.join(d, s.PHRASES), "w", encoding="utf-8") as f:
                f.write(shipped)

        def edit(pc, *words):  # My words become words
            have = {(p, w) for p, w, _, _ in s.rime_words(pc[0]) or []}
            s.save_rime_words(pc[0], words, have)

        def sync(pc):
            s.pull(client, pc[1], pc[2], rime_dir=pc[0])
            s.push(client, pc[1], pc[2], rime_dir=pc[0])
            return sorted(w for _, w, _, _ in s.rime_words(pc[0]) or [])

        a, b = pcs
        self.assertEqual(sync(a), [], "no My words yet: nothing to tell")
        edit(a, ("pumoli", "噗莫里"))
        edit(b, ("gulaxi", "咕拉西"))
        sync(a), sync(b)
        self.assertEqual(sync(a), ["咕拉西", "噗莫里"])
        self.assertEqual(sync(b), ["咕拉西", "噗莫里"])
        with open(os.path.join(b[0], s.PHRASES), encoding="utf-8") as f:
            self.assertTrue(f.read().startswith(shipped + s.MARKER + "\n"))

        edit(a, ("pumoli", "噗莫里"))
        sync(a)
        self.assertEqual(sync(b), ["噗莫里"], "deleted on a, so on b too")
        self.assertEqual(sync(a), ["噗莫里"], "and b's file doesn't bring it back")

        edit(b, ("pumoli", "噗莫里"), ("gulaxi", "咕拉西"))
        sync(b)
        self.assertEqual(sync(a), ["咕拉西", "噗莫里"], "added again on b")
        self.assertEqual(
            self.call("GET", "/v1/files/zh-a/" + s.ZH_FILE)[0], 200, "a Rime-named file"
        )

    def test_chinese_words_a_client_before_272_kept_come_in(self):
        """A client before #272 stored another device's Chinese file as one of Rime's snapshots
        without taking its words in: once upgraded, it takes them in all the same."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        (d,) = self.rime_dirs("zh-c")
        device, sync_dir = s.rime_installation(d)
        other = (
            "pumoli\t噗莫里\t名詞\n".encode()
        )  # from that device's first sync: no time
        self.call("PUT", "/v1/files/zh-d/" + s.ZH_FILE, other)
        s.write_file(os.path.join(sync_dir, "zh-d", s.ZH_FILE), other)  # the old way
        self.assertEqual(s.pull(client, device, sync_dir, rime_dir=d), (1, 0, 1, 0))
        self.assertEqual(s.rime_words(d), [("pumoli", "噗莫里", s.NOUN, "")])

    def test_chinese_first_sync_cut_off_after_one_device(self):
        """Two devices' files kept by a client before #272; the first sync after the update takes in
        one, then fails: the next one still takes in the other's words."""
        self.call("DELETE", "/v1/files")
        client = s.Client(self.url, "alice", "made-up-pass")
        (d,) = self.rime_dirs("zh-f")
        device, sync_dir = s.rime_installation(d)
        for peer, word in (("zh-g", "pumoli\t噗莫里"), ("zh-h", "gulaxi\t咕拉西")):
            body = f"{word}\t名詞\n".encode()
            self.call("PUT", f"/v1/files/{peer}/{s.ZH_FILE}", body)
            s.write_file(os.path.join(sync_dir, peer, s.ZH_FILE), body)  # the old way

        class CutOff(s.Client):
            def request(self, method, path, body=None):
                if path.endswith(f"zh-h/{s.ZH_FILE}"):
                    raise OSError("made-up network failure")
                return super().request(method, path, body)

        with self.assertRaises(OSError):
            s.pull(
                CutOff(self.url, "alice", "made-up-pass"), device, sync_dir, rime_dir=d
            )
        self.assertEqual([w for _, w, _, _ in s.rime_words(d)], ["噗莫里"])
        s.pull(client, device, sync_dir, rime_dir=d)
        self.assertEqual(
            sorted(w for _, w, _, _ in s.rime_words(d)), ["咕拉西", "噗莫里"]
        )

    def test_chinese_take_in_keeps_the_other_rows(self):
        """A change from another device touches only its own row: the others keep their weights and
        comments."""
        (d,) = self.rime_dirs("zh-i")
        rows = f"# made up\n{s.MARKER}\n咕拉西\tgulaxi\t100\n# a made-up note\n"
        with open(os.path.join(d, s.PHRASES), "w", encoding="utf-8") as f:
            f.write(rows)
        own = os.path.join(d, "own.txt")
        s.own_file(own, s.rime_words(d), now=1)
        s.rime_take_in(d, own, "pumoli\t噗莫里\t名詞\t\t50\n".encode(), None, now=60)
        with open(os.path.join(d, s.PHRASES), encoding="utf-8") as f:
            self.assertEqual(f.read(), rows + "噗莫里\tpumoli\n")

    def test_chinese_clock_ahead_and_no_phrases_file(self):
        """A deletion after a word dated in the future still wins; a PC with no My words yet reads as
        having none to tell, not as having deleted them all."""
        (d,) = self.rime_dirs("zh-e")
        own = os.path.join(d, "own.txt")
        self.assertIsNone(s.rime_words(d))
        ahead = "pumoli\t噗莫里\t名詞\t\t5000\n".encode()
        self.assertEqual(s.rime_take_in(d, own, ahead, None, now=100), 1)
        s.save_rime_words(d, [], {("pumoli", "噗莫里")})
        own_entries = s.own_file(own, s.rime_words(d), now=200)
        self.assertEqual(own_entries[("pumoli", "噗莫里")].time, 5001)
        self.assertTrue(own_entries[("pumoli", "噗莫里")].deleted)
        self.assertEqual(
            s.rime_take_in(d, own, ahead, None, now=300), 0, "stays deleted"
        )

    def test_old_clients(self):
        """A client from before #273 still reads a new file's words, which keep Mozc's export columns,
        and skips its deletions; its own file's words come in only when it gained them, so a word
        deleted here doesn't come back from it, and its deletions stay its own."""
        new = s.format_entries(
            s.stamp(
                {
                    ("ぴぴ", "ピピ丸"): s.Entry("ぴぴ", "ピピ丸", 1),
                    ("もふ", "モフ"): s.Entry("もふ", "モフ", 1),
                },
                [("ぴぴ", "ピピ丸", 5, "made up")],
                1234,
            )
        ).decode()
        self.assertEqual(
            new, "#-\tもふ\tモフ\t\t\t1234\nぴぴ\tピピ丸\t人名\tmade up\t1234\n"
        )
        old_reader = [
            line.split("\t")[:3]
            for line in new.splitlines()
            if not line.startswith("#")
        ]
        self.assertEqual(old_reader, [["ぴぴ", "ピピ丸", "人名"]])

        own = {("もふ", "モフ"): s.Entry("もふ", "モフ", 1, "", 50, True)}
        before = "\ufeffもふ\tモフ\t名詞\n".encode()  # a Mozc export starts with a BOM
        after = "もふ\tモフ\t名詞\nぐる\tグル\t名詞\tPC\n".encode()
        changes = s.merge(own, after, before)
        self.assertEqual([e.key for e in changes], [("ぐる", "グル")])
        self.assertTrue(own[("もふ", "モフ")].deleted)
        self.assertEqual(s.merge(own, b"", after), [], "its deletions stay its own")


if __name__ == "__main__":
    unittest.main()
