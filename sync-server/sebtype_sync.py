#!/usr/bin/env python3
"""SebType's sync server and its PC client (#12, #14): a self-hostable home for Rime's sync folders.

Rime syncs learned words through a folder, `sync/<installation id>/`: every device writes only its own
folder and merges in everyone else's, so a server that keeps one copy of each device's folder per user
is all sync needs (study report on #3, section 6). The same folders carry each device's Japanese and
English personal dictionaries (#14), its Chinese My words (#272) and the conversions it picked in
Mozc (#409); Japanese and Chinese deletions and edits sync too (#273). The server stores these files and the phone's crash reports (#33)
and nothing else, behind its own usernames and passwords (scrypt-hashed in users.json). It speaks plain
HTTP on 127.0.0.1 by default: put an HTTPS reverse proxy in front of it, or give it a certificate.

    sebtype_sync.py serve   --data DIR [--host H] [--port P] [--tls-cert F --tls-key F]
    sebtype_sync.py adduser --data DIR NAME [--password-stdin]
    sebtype_sync.py deluser --data DIR NAME          (also deletes the user's files and crash reports)
    sebtype_sync.py pull|push --server URL --user NAME (--password-file F | --password-stdin) --rime-dir DIR [--mozc-db F]
    sebtype_sync.py delete    --server URL --user NAME (--password-file F | --password-stdin)

The client exits with 3 when the server refuses the login, and 1 on any other failure.

API, all with HTTP Basic auth:
    GET    /v1/files                  {"files": [{"device", "name", "size", "sha256"}]}
    GET    /v1/files/<device>/<name>  the file
    PUT    /v1/files/<device>/<name>  stores the file (a device writes only its own folder)
    DELETE /v1/files                  deletes all of the user's files
    PUT    /v1/crashes/<name>         stores a SebType crash report in crashes/<user>/ (#33)

Python 3.9+, standard library only.
"""

import argparse
import base64
import contextlib
import getpass
import hashlib
import hmac
import http.server
import json
import os
import re
import secrets
import shutil
import ssl
import sys
import tempfile
import time
import urllib.error
import urllib.request

NAME = re.compile(
    r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}"
)  # users and devices (Rime's ids are UUIDs)
RIME_FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.userdb\.txt")
# A device's Japanese personal dictionary in Mozc's export format, and its other (English) words in
# FUTO's userdictionary.json format, which only phones have.
MOZC_FILE, WORDS_FILE = "mozc_dictionary.txt", "userdictionary.json"
# A device's Chinese My words (#272), in the Japanese file's format. Named like Rime's snapshots so
# servers and clients from before #272 store and pass it on unchanged; Rime takes in only the
# snapshots of its own user dictionaries (rime_ice.userdb.txt), so it never reads this one.
ZH_FILE = "zh_my_words.userdb.txt"
# The conversions a device's user picked in Mozc (#409): its record, which SebType's Mozc keeps in Mozc's
# folder (core/src/mozc_learned.h) and learns the other devices' records from, in mozc_learned/<device>.txt.
LEARNED_FILE, LEARNED_DIR = "mozc_learned.txt", "mozc_learned"
MAX_FILE = 64 << 20  # a userdb snapshot of years of typing is a few MB
CRASH = re.compile(r"crash-\d{8}-\d{6}-[0-9a-f]{6}\.txt")
MAX_CRASH = 256 << 10  # a report is a stack trace and 200 log lines, a few dozen KB
SCRYPT = {"n": 1 << 14, "r": 8, "p": 1}


def synced(name):
    """Whether a file name is one the server keeps."""
    return bool(RIME_FILE.fullmatch(name)) or name in (
        MOZC_FILE,
        WORDS_FILE,
        LEARNED_FILE,
    )


# --- Users ---


def hash_password(password):
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, dklen=32, **SCRYPT)
    return (
        f"scrypt${SCRYPT['n']}${SCRYPT['r']}${SCRYPT['p']}${salt.hex()}${digest.hex()}"
    )


def check_password(password, stored):
    _, n, r, p, salt, digest = stored.split("$")
    got = hashlib.scrypt(
        password.encode(),
        salt=bytes.fromhex(salt),
        n=int(n),
        r=int(r),
        p=int(p),
        dklen=32,
    )
    return hmac.compare_digest(got.hex(), digest)


def load_users(data):
    try:
        with open(os.path.join(data, "users.json"), encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_users(data, users):
    os.makedirs(data, exist_ok=True)
    path = os.path.join(data, "users.json")
    fd, tmp = tempfile.mkstemp(dir=data)
    with os.fdopen(fd, "w", encoding="utf-8") as f:  # mkstemp makes it 0600
        json.dump(users, f, indent=1)
    os.replace(tmp, path)


# --- Server ---


class Handler(http.server.BaseHTTPRequestHandler):
    data = None  # set by serve()
    protocol_version = "HTTP/1.1"
    server_version = "sebtype-sync"
    sys_version = ""

    def log_request(self, code="-", size="-"):
        # Method, path (device ids and file names, no words) and status; never the credentials.
        self.log_message("%s %s %s", self.command, self.path.split("?")[0], code)

    def reply(self, code, body=b"", kind="text/plain; charset=utf-8"):
        if isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        if code == 401:
            self.send_header(
                "WWW-Authenticate", 'Basic realm="sebtype-sync", charset="UTF-8"'
            )
        self.end_headers()
        self.wfile.write(body)

    def user(self):
        """The authenticated user's name, or None after replying 401."""
        header = self.headers.get("Authorization", "")
        try:
            assert header.startswith("Basic ")
            name, password = (
                base64.b64decode(header[6:], validate=True).decode().split(":", 1)
            )
            stored = load_users(self.data).get(name)
            if stored and check_password(password, stored):
                return name
        except (AssertionError, ValueError, UnicodeDecodeError):
            pass
        time.sleep(1)  # slows down guessing
        self.reply(401, "login needed\n")
        return None

    def target(self):
        """(device, name) from /v1/files/<device>/<name>, or None."""
        parts = self.path.split("?")[0].split("/")
        if len(parts) == 5 and parts[:3] == ["", "v1", "files"]:
            device, name = parts[3], parts[4]
            if NAME.fullmatch(device) and synced(name):
                return device, name
        return None

    def files_dir(self, user):
        return os.path.join(self.data, "files", user)

    def do_GET(self):
        user = self.user()
        if not user:
            return
        root = self.files_dir(user)
        if self.path.split("?")[0] == "/v1/files":
            files = []
            for device in sorted(os.listdir(root)) if os.path.isdir(root) else []:
                for name in sorted(os.listdir(os.path.join(root, device))):
                    path = os.path.join(root, device, name)
                    if synced(name):  # not an upload in progress
                        files.append(
                            {
                                "device": device,
                                "name": name,
                                "size": os.path.getsize(path),
                                "sha256": sha256_of(path),
                            }
                        )
            return self.reply(200, json.dumps({"files": files}), "application/json")
        target = self.target()
        if not target:
            return self.reply(404, "not found\n")
        path = os.path.join(root, *target)
        if not os.path.isfile(path):
            return self.reply(404, "not found\n")
        with open(path, "rb") as f:
            self.reply(200, f.read(), "application/octet-stream")

    def do_PUT(self):
        user = self.user()
        if not user:
            return
        if self.path.startswith("/v1/crashes/"):
            return self.put_crash(user)
        target = self.target()
        if not target:
            return self.reply(404, "not found\n")
        length = int(self.headers.get("Content-Length") or -1)
        if not 0 <= length <= MAX_FILE:
            self.close_connection = True
            return self.reply(413, "too large or no length\n")
        body = self.rfile.read(length)
        folder = os.path.join(self.files_dir(user), target[0])
        os.makedirs(folder, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".upload-")
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        os.replace(tmp, os.path.join(folder, target[1]))
        self.reply(204)

    def put_crash(self, user):
        """Stores a crash report from the phone (#33) in crashes/<user>/, next to files/, never replacing one."""
        name = self.path.split("?")[0][len("/v1/crashes/") :]
        if not CRASH.fullmatch(name):
            return self.reply(404, "not found\n")
        length = int(self.headers.get("Content-Length") or -1)
        if not 0 <= length <= MAX_CRASH:
            self.close_connection = True
            return self.reply(413, "too large or no length\n")
        body = self.rfile.read(length)
        folder = os.path.join(self.data, "crashes", user)
        os.makedirs(folder, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=folder, prefix=".upload-")
        with os.fdopen(fd, "wb") as f:
            f.write(body)
        os.replace(
            tmp, os.path.join(folder, name)
        )  # the same name is the same report, sent again
        self.reply(204)

    def do_DELETE(self):
        user = self.user()
        if not user:
            return
        if self.path.split("?")[0] != "/v1/files":
            return self.reply(404, "not found\n")
        shutil.rmtree(self.files_dir(user), ignore_errors=True)
        self.reply(204)


def serve(args):
    Handler.data = args.data
    server = http.server.ThreadingHTTPServer((args.host, args.port), Handler)
    if args.tls_cert:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(args.tls_cert, args.tls_key)
        server.socket = context.wrap_socket(server.socket, server_side=True)
    scheme = "https" if args.tls_cert else "http"
    print(
        f"sebtype-sync on {scheme}://{args.host}:{args.port}, data in {args.data}",
        flush=True,
    )
    server.serve_forever()


# --- PC client ---


def rime_installation(rime_dir):
    """(installation id, sync dir) from Rime's installation.yaml in its user dir."""
    values = {}
    with open(os.path.join(rime_dir, "installation.yaml"), encoding="utf-8") as f:
        for line in f:
            m = re.match(r'\s*(installation_id|sync_dir)\s*:\s*"?([^"#]*?)"?\s*$', line)
            if m:
                values[m[1]] = m[2]
    return values["installation_id"], values.get("sync_dir") or os.path.join(
        rime_dir, "sync"
    )


class Client:
    def __init__(self, server, user, password):
        self.base = server.rstrip("/")
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def request(self, method, path, body=None):
        req = urllib.request.Request(self.base + path, data=body, method=method)
        req.add_header("Authorization", self.auth)
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read()

    def files(self):
        return json.loads(self.request("GET", "/v1/files"))["files"]


def sha256_of(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


# --- Mozc's user dictionary (user_dictionary.db, a UserDictionaryStorage protobuf; #14) ---

# Mozc's parts of speech, in the order of its PosType enum, by the names its export and import use.
POS = [
    "品詞なし",
    "名詞",
    "短縮よみ",
    "サジェストのみ",
    "固有名詞",
    "人名",
    "姓",
    "名",
    "組織",
    "地名",
    "名詞サ変",
    "名詞形動",
    "数",
    "アルファベット",
    "記号",
    "顔文字",
    "副詞",
    "連体詞",
    "接続詞",
    "感動詞",
    "接頭語",
    "助数詞",
    "接尾一般",
    "接尾人名",
    "接尾地名",
    "動詞ワ行五段",
    "動詞カ行五段",
    "動詞サ行五段",
    "動詞タ行五段",
    "動詞ナ行五段",
    "動詞マ行五段",
    "動詞ラ行五段",
    "動詞ガ行五段",
    "動詞バ行五段",
    "動詞ハ行四段",
    "動詞一段",
    "動詞カ変",
    "動詞サ変",
    "動詞ザ変",
    "動詞ラ変",
    "形容詞",
    "終助詞",
    "句読点",
    "独立語",
    "抑制単語",
]
NOUN = 1  # an entry's part of speech when it has none, and for a name Mozc doesn't know
# SebType's dictionary in Mozc: the Configurator's My words, and where other devices' words go (#273).
# Before #273 they went to one of their own, "SebType sync", which the Configurator now merges into it.
DICTIONARY = "SebType"


def varint(data, i):
    n = shift = 0
    while True:
        b = data[i]
        n |= (b & 0x7F) << shift
        i += 1
        if b < 0x80:
            return n, i
        shift += 7


def pb_fields(data):
    """A protobuf message's fields as (number, value, start, end): value is an int or the bytes of a
    length-delimited field; start and end span the field's whole encoding, to copy it unchanged."""
    i, fields = 0, []
    while i < len(data):
        start = i
        tag, i = varint(data, i)
        number, kind = tag >> 3, tag & 7
        if kind == 0:
            value, i = varint(data, i)
        elif kind == 2:
            size, i = varint(data, i)
            value, i = data[i : i + size], i + size
        elif kind in (1, 5):
            value, i = (
                data[i : i + (8 if kind == 1 else 4)],
                i + (8 if kind == 1 else 4),
            )
        else:
            raise ValueError(f"protobuf wire type {kind}")
        fields.append((number, value, start, i))
    return fields


def pb_varint(n):
    out = bytearray()
    while n >= 0x80:
        out.append(n & 0x7F | 0x80)
        n >>= 7
    return bytes(out + bytes([n]))


def pb_field(number, value):
    if isinstance(value, int):
        return pb_varint(number << 3) + pb_varint(value)
    value = value.encode() if isinstance(value, str) else value
    return pb_varint(number << 3 | 2) + pb_varint(len(value)) + value


def mozc_words(db):
    """(reading, word, part of speech, comment) of every word the user registered: in enabled
    dictionaries, not removed, and not one Mozc registered by itself."""
    words = []
    for number, dictionary, _, _ in pb_fields(db):
        d = {n: v for n, v, _, _ in pb_fields(dictionary)} if number == 2 else {}
        if number != 2 or not d.get(2, 1) or d.get(5):
            continue
        for n, entry, _, _ in pb_fields(dictionary):
            e = {k: v for k, v, _, _ in pb_fields(entry)} if n == 4 else {}
            if n == 4 and not e.get(10) and not e.get(11) and e.get(1) and e.get(2):
                pos = e.get(5, NOUN)
                words.append(
                    (
                        e[1].decode(),
                        e[2].decode(),
                        pos if pos < len(POS) else NOUN,
                        e.get(4, b"").decode(),
                    )
                )
    return words


def mozc_add(db, words):
    """db with words, (reading, word, part of speech[, comment]), added to SebType's dictionary, the
    one the Configurator's My words shows (#273), made if missing; the rest kept unchanged."""
    entries = b"".join(
        pb_field(
            4,
            pb_field(1, r)
            + pb_field(2, w)
            + pb_field(5, p)
            + b"".join(pb_field(4, c) for c in comment if c),
        )
        for r, w, p, *comment in words
    )
    out = bytearray()
    for number, dictionary, start, end in pb_fields(db):
        d = {n: v for n, v, _, _ in pb_fields(dictionary)} if number == 2 else {}
        if entries and d.get(3) == DICTIONARY.encode() and not d.get(5):
            out += pb_field(2, dictionary + entries)
            entries = b""
        else:
            out += db[start:end]
    if entries:
        # Mozc's dictionary ids are random, unique and not 0.
        out += pb_field(
            2,
            pb_field(1, secrets.randbits(63) | 1)
            + pb_field(2, 1)
            + pb_field(3, DICTIONARY)
            + entries,
        )
    return bytes(out)


def mozc_remove(db, keys):
    """db without the entries of enabled dictionaries whose (reading, word) is in keys."""
    out = bytearray()
    for number, dictionary, start, end in pb_fields(db):
        d = {n: v for n, v, _, _ in pb_fields(dictionary)} if number == 2 else {}
        if number != 2 or not d.get(2, 1) or d.get(5):
            out += db[start:end]
            continue
        kept = bytearray()
        for n, entry, s, e in pb_fields(dictionary):
            f = {k: v for k, v, _, _ in pb_fields(entry)} if n == 4 else {}
            if n != 4 or (f.get(1, b"").decode(), f.get(2, b"").decode()) not in keys:
                kept += dictionary[s:e]
        out += pb_field(2, bytes(kept))
    return bytes(out)


# --- Deletions and edits (#273) ---
#
# Each device's mozc_dictionary.txt is its Japanese words in Mozc's export format, and since #273 also
# the time each word last changed there and the words deleted there, in columns and lines older
# clients skip:
#
#     reading<TAB>word<TAB>part of speech<TAB>comment<TAB>time     a word, changed at time (ms since 1970)
#     #-<TAB>reading<TAB>word<TAB><TAB><TAB>time                    a word deleted at time
#
# A word is its reading and spelling; its part of speech is what an edit changes. Every device keeps
# its own file as the record of what it last had, so a sync can tell what changed on it since then
# and date those changes. Taking in another device's file, each word's newest change wins: a newer
# deletion deletes it here, a newer addition or edit adds it or changes it here, and an older one
# changes nothing. Times are the devices' clocks. On a tie an addition wins over a deletion.
# A word without a time (from a client before #273, or one a device had when it first synced with
# this version) is taken in only when that device's file gained it since the copy taken last time,
# as before #273, so a word deleted before then doesn't come back.

DELETED = "#-\t"


class Entry(tuple):
    """(reading, word, part of speech, comment, time, deleted) of one word in a sync file."""

    __slots__ = ()

    def __new__(cls, reading, word, pos, comment="", time=0, deleted=False):
        return tuple.__new__(cls, (reading, word, pos, comment, time, deleted))

    key = property(lambda e: (e[0], e[1]))
    pos = property(lambda e: e[2])
    comment = property(lambda e: e[3])
    time = property(lambda e: e[4])
    deleted = property(lambda e: e[5])

    def rank(self):
        """Which of two changes to a word wins: the newer, an addition on a tie, then any fixed order."""
        return self.time, not self.deleted, POS[self.pos]  # as the phones compare them


def parse_entries(data):
    """A sync file's words by (reading, word), the newest change of each."""
    entries = {}
    for line in data.decode("utf-8", "replace").lstrip("\ufeff").splitlines():
        deleted = line.startswith(DELETED)
        if deleted:
            line = line[len(DELETED) :]
        elif line.startswith("#"):
            continue
        f = line.split("\t") + [""] * 4
        if not f[0] or not f[1] or (not deleted and line.count("\t") < 2):
            continue
        e = Entry(
            f[0],
            f[1],
            POS.index(f[2]) if f[2] in POS else NOUN,
            f[3],
            int(f[4]) if f[4].isdigit() else 0,
            deleted,
        )
        if e.key not in entries or e.rank() > entries[e.key].rank():
            entries[e.key] = e
    return entries


def format_entries(entries):
    """A sync file, sorted so an unchanged dictionary uploads nothing."""
    lines = []
    for e in entries.values():
        if e.deleted:
            lines.append(DELETED + "\t".join([e[0], e[1], "", "", str(e.time)]))
        else:
            dated = (
                [e.comment, str(e.time)] if e.time else [e.comment] if e.comment else []
            )
            lines.append("\t".join([e[0], e[1], POS[e.pos]] + dated))
    return "".join(line + "\n" for line in sorted(lines)).encode()


def stamp(own, words, now):
    """This device's file own (None before its first sync) brought up to date with its words, dating
    what changed since. A first sync dates nothing: what was deleted before it stays a local matter.
    A change is dated after the one it replaces, even one from a device whose clock ran ahead, so the
    later change wins everywhere."""
    if words is None:  # no dictionary (yet), so nothing to tell
        return dict(own or {})
    first = own is None
    own = dict(own or {})

    def when(e):
        return 0 if first else max(now, e.time + 1) if e else now

    have = {(r, w): (p, c) for r, w, p, c in words}
    for key, (pos, comment) in have.items():
        e = own.get(key)
        if e is None or e.deleted or e.pos != pos:
            own[key] = Entry(*key, pos, comment, when(e))
        elif e.comment != comment:
            own[key] = Entry(*key, pos, comment, e.time)
    for key, e in list(own.items()):
        if not e.deleted and key not in have:
            own[key] = Entry(*key, NOUN, "", when(e), True)  # no part of speech
    return own


def merge(own, new, old):
    """Takes another device's file new (and the copy old taken of it last time) into this device's
    file own; returns the changes that win, which this device's dictionary then gets."""
    before = parse_entries(old or b"")
    changes = []
    for key, e in parse_entries(new).items():
        mine = own.get(key)
        if e.time:
            wins = mine is None or e.rank() > mine.rank()
        else:
            wins = mine is None and key not in before and not e.deleted
        if not wins:
            continue
        own[key] = e
        if not (e.deleted and (mine is None or mine.deleted)):
            changes.append(e)
    return changes


def own_file(own_path, words, now=None):
    """This device's sync file, kept at own_path, brought up to date with its words (None: none)."""
    try:
        with open(own_path, "rb") as f:
            own = parse_entries(f.read())
    except FileNotFoundError:
        own = None
    own = stamp(own, words, now or time.time_ns() // 10**6)
    write_file(own_path, format_entries(own))
    return own


def own_mozc(db_path, own_path, now=None):
    """This device's Japanese sync file, kept at own_path, brought up to date with Mozc's dictionary."""
    db = read_mozc(db_path)
    return own_file(own_path, None if db is None else mozc_words(db), now)


@contextlib.contextmanager
def mozc_lock(db):
    """Mozc's own lock on its dictionary (Linux): held while its dictionary tool is open."""
    try:
        import fcntl
    except ImportError:  # Windows: close the dictionary tool first
        yield
        return
    path = os.path.join(os.path.dirname(db), "." + os.path.basename(db) + ".lock")
    with open(path, "a") as f:
        try:
            fcntl.lockf(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            sys.exit("Mozc's dictionary tool is open: close it, then run pull again")
        yield


def read_mozc(db_path):
    """Mozc saves its dictionary by renaming a new file over it, so a read needs no lock. None when
    there is none: no word registered yet, or not Mozc's folder."""
    try:
        with open(db_path, "rb") as f:
            return f.read()
    except FileNotFoundError:
        return None


def mozc_take_in(db_path, own_path, new, old, now=None):
    """Takes another device's Mozc file into Mozc's dictionary, and into this device's file at
    own_path; returns how many words were added, changed or deleted."""
    with mozc_lock(db_path):
        own = own_mozc(
            db_path, own_path, now
        )  # first dates this PC's own changes, so they can win
        comments = {key: e.comment for key, e in own.items()}
        changes = merge(own, new, old)
        if changes:
            db = read_mozc(db_path) or b""
            if db:
                shutil.copyfile(db_path, db_path + ".sebtype-backup")
            db = mozc_remove(db, {e.key for e in changes})
            added = [e for e in changes if not e.deleted]
            db = mozc_add(
                db,
                [(*e.key, e.pos, e.comment or comments.get(e.key, "")) for e in added],
            )
            write_file(db_path, db)
        # After the dictionary, so a sync cut off in between takes the file in again; always, since
        # a deletion of a word this PC lacks changes only this.
        write_file(own_path, format_entries(own))
        return len(changes)


# --- Chinese My words (#272) ---
#
# The Configurator keeps them in Rime's custom_phrase.txt after MARKER, as word<TAB>pinyin lines, after
# rime-ice's own phrases (pc/configurator/src/rime.rs; the phones the same). They sync by the rules
# above, a word being its pinyin and spelling: in the sync file pinyin<TAB>word<TAB>名詞, the part of
# speech only filling Mozc's column.

PHRASES, MARKER = "custom_phrase.txt", "# SebType: My words"


def rime_words(rime_dir):
    """(pinyin, word, part of speech, comment) of the My words in custom_phrase.txt; None when
    there is no My words section (never saved), so a missing file isn't read as all deleted."""
    try:
        with open(os.path.join(rime_dir, PHRASES), encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return None
    if MARKER not in lines:
        return None
    words = []
    for line in lines[lines.index(MARKER) + 1 :]:
        f = line.split("\t")
        if len(f) >= 2 and f[0] and f[1]:
            words.append((f[1], f[0], NOUN, ""))
    return words


def save_rime_words(rime_dir, words, gone=()):
    """Writes My words after rime-ice's own phrases: drops the rows of the (pinyin, word) keys in gone
    and appends words, (pinyin, word). Every other row stays as it is, its weight and comments too."""
    path = os.path.join(rime_dir, PHRASES)
    try:
        with open(path, encoding="utf-8") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        lines = []
    if MARKER not in lines:
        lines.append(MARKER)
    at = lines.index(MARKER) + 1

    def key(line):
        f = line.split("\t")
        return (f[1], f[0]) if len(f) >= 2 else None

    rows = [line for line in lines[at:] if key(line) not in gone]
    body = lines[:at] + rows + [f"{w}\t{p}" for p, w in words]
    write_file(path, "".join(line + "\n" for line in body).encode())


def rime_take_in(rime_dir, own_path, new, old, now=None):
    """Takes another device's Chinese file into My words and this device's file at own_path; returns
    how many words were added or deleted. Rime reads My words when it deploys. The Configurator holds
    its words lock meanwhile (sync.rs), so a word saved in its window can't be lost in between."""
    have = rime_words(rime_dir)
    own = own_file(own_path, have, now)
    changes = merge(own, new, old)
    if changes:
        save_rime_words(
            rime_dir,
            [e.key for e in changes if not e.deleted],
            {e.key for e in changes},
        )
    write_file(own_path, format_entries(own))  # after My words, as for Mozc
    return len(changes)


# --- PC client: pull and push ---


def write_file(path, body):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "wb") as out:
        out.write(body)
    os.replace(tmp, path)


def pull(client, device, sync_dir, mozc_db=None, rime_dir=None):
    """Downloads every other device's changed files into sync_dir/<device>/, takes their Chinese words'
    changes into rime_dir's My words and with mozc_db their Japanese words' into Mozc, and their
    learned conversions next to it for Mozc to learn; returns (files, Japanese words added, changed or
    deleted, Chinese ones, learned conversions' records)."""
    count = words = chinese = learned = 0
    own_zh = os.path.join(sync_dir, device, ZH_FILE)
    if rime_dir and not os.path.isfile(own_zh):
        # A client from before #272 kept copies of other devices' Chinese files without taking their
        # words in, so they aren't what this device took in last time: gone before its own file starts,
        # so a first sync cut off after one device's file still takes in the others'.
        for other in os.listdir(sync_dir) if os.path.isdir(sync_dir) else []:
            with contextlib.suppress(FileNotFoundError):
                os.remove(os.path.join(sync_dir, other, ZH_FILE))
    for f in client.files():
        name = f["name"]
        # The copy kept of a Mozc or Chinese file is what its next download is compared with: it is
        # taken only along with its words. Nothing on a PC uses another device's English words.
        if (
            f["device"] == device
            or not (NAME.fullmatch(f["device"]) and synced(name))
            or name == WORDS_FILE
            or (name in (MOZC_FILE, LEARNED_FILE) and not mozc_db)
            or (name == ZH_FILE and not rime_dir)
        ):
            continue
        path = os.path.join(sync_dir, f["device"], name)
        if name == LEARNED_FILE:  # SebType's Mozc learns it when it next starts
            path = os.path.join(
                os.path.dirname(mozc_db), LEARNED_DIR, f"{f['device']}.txt"
            )
        old = None
        if os.path.isfile(path):
            with open(path, "rb") as fh:
                old = fh.read()
            if hashlib.sha256(old).hexdigest() == f["sha256"]:
                continue
        body = client.request("GET", f"/v1/files/{f['device']}/{name}")
        if name == MOZC_FILE:
            own = os.path.join(sync_dir, device, MOZC_FILE)
            words += mozc_take_in(mozc_db, own, body, old)
        elif name == ZH_FILE:
            chinese += rime_take_in(rime_dir, own_zh, body, old)
        elif name == LEARNED_FILE:
            learned += 1
        write_file(path, body)
        count += 1
    return count, words, chinese, learned


def push(client, device, sync_dir, mozc_db=None, rime_dir=None):
    """Uploads this device's changed snapshots (learned words, not Rime's yaml backups), with rime_dir
    its Chinese words and with mozc_db its Japanese words (its own files, kept in its folder); returns
    how many."""
    remote = {f["name"]: f["sha256"] for f in client.files() if f["device"] == device}
    files = {}
    folder = os.path.join(sync_dir, device)
    if rime_dir:
        own_file(
            os.path.join(folder, ZH_FILE), rime_words(rime_dir)
        )  # read with the snapshots
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if RIME_FILE.fullmatch(name):
            with open(os.path.join(folder, name), "rb") as f:
                files[name] = f.read()
    if mozc_db:
        files[MOZC_FILE] = format_entries(
            own_mozc(mozc_db, os.path.join(folder, MOZC_FILE))
        )
        with contextlib.suppress(FileNotFoundError):
            with open(os.path.join(os.path.dirname(mozc_db), LEARNED_FILE), "rb") as f:
                files[LEARNED_FILE] = f.read()
    count = 0
    for name, body in files.items():
        if remote.get(name) != hashlib.sha256(body).hexdigest():
            try:
                client.request("PUT", f"/v1/files/{device}/{name}", body)
            except urllib.error.HTTPError as e:
                # A server from before #409 keeps no learned conversions: the rest still syncs.
                if not (name == LEARNED_FILE and e.code == 404):
                    raise
                continue
            count += 1
    return count


def run_client(args):
    if (
        args.password_stdin
    ):  # the SebType Configurator's way: the login stays in the system's keyring
        password = sys.stdin.readline().rstrip("\n")
    else:
        with open(args.password_file, encoding="utf-8") as f:
            password = f.read().strip()
    client = Client(args.server, args.user, password)
    if args.command != "delete":
        device, sync_dir = rime_installation(args.rime_dir)
    try:
        if args.command == "delete":
            client.request("DELETE", "/v1/files")
            print("delete: done")
        elif args.command == "pull":
            files, words, chinese, learned = pull(
                client, device, sync_dir, args.mozc_db, args.rime_dir
            )
            # The Configurator reads the counts by their place (sync.rs).
            print(
                f"pull: {files} file(s), {words} word change(s) for Mozc, "
                f"{chinese} for Rime, {learned} learned conversions' record(s)"
            )
        else:
            print(
                f"push: {push(client, device, sync_dir, args.mozc_db, args.rime_dir)} file(s)"
            )
    except urllib.error.HTTPError as e:
        print(f"{args.command}: the server said {e.code}", file=sys.stderr)
        sys.exit(3 if e.code in (401, 403) else 1)
    except OSError as e:
        sys.exit(f"{args.command}: can't reach the server ({type(e).__name__})")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = p.add_subparsers(dest="command", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--data", required=True)
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, default=8740)
    s.add_argument("--tls-cert")
    s.add_argument("--tls-key")
    for command in ("adduser", "deluser"):
        u = sub.add_parser(command)
        u.add_argument("--data", required=True)
        u.add_argument("name")
        if command == "adduser":
            u.add_argument("--password-stdin", action="store_true")
    for command in ("pull", "push", "delete"):
        c = sub.add_parser(command)
        c.add_argument("--server", required=True)
        c.add_argument("--user", required=True)
        password = c.add_mutually_exclusive_group(required=True)
        password.add_argument("--password-file")
        password.add_argument(
            "--password-stdin", action="store_true", help="the password's first line"
        )
        if command == "delete":
            continue  # every device's files of this user, on the server only
        c.add_argument(
            "--rime-dir", required=True, help="Rime's user dir, with installation.yaml"
        )
        c.add_argument(
            "--mozc-db", help="Mozc's user_dictionary.db, to sync its Japanese words"
        )
    args = p.parse_args()

    if args.command == "serve":
        serve(args)
    elif args.command in ("adduser", "deluser"):
        if not NAME.fullmatch(args.name):
            sys.exit("a name is letters, digits, '.', '_' and '-', at most 64")
        users = load_users(args.data)
        if args.command == "adduser":
            password = (
                sys.stdin.readline().rstrip("\n")
                if args.password_stdin
                else getpass.getpass()
            )
            if len(password) < 8:
                sys.exit("the password needs at least 8 characters")
            users[args.name] = hash_password(password)
        else:
            users.pop(args.name, None)
            for kind in ("files", "crashes"):
                shutil.rmtree(
                    os.path.join(args.data, kind, args.name), ignore_errors=True
                )
        save_users(args.data, users)
    else:
        run_client(args)


if __name__ == "__main__":
    main()
