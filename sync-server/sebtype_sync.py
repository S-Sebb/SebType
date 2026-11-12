#!/usr/bin/env python3
"""SebType's sync server and its PC client (#12, #14): a self-hostable home for Rime's sync folders.

Rime syncs learned words through a folder, `sync/<installation id>/`: every device writes only its own
folder and merges in everyone else's, so a server that keeps one copy of each device's folder per user
is all sync needs (study report on #3, section 6). The same folders carry each device's Japanese and
English personal dictionaries (#14). The server stores these files and the phone's crash reports (#33)
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
MAX_FILE = 64 << 20  # a userdb snapshot of years of typing is a few MB
CRASH = re.compile(r"crash-\d{8}-\d{6}-[0-9a-f]{6}\.txt")
MAX_CRASH = 256 << 10  # a report is a stack trace and 200 log lines, a few dozen KB
SCRYPT = {"n": 1 << 14, "r": 8, "p": 1}


def synced(name):
    """Whether a file name is one the server keeps."""
    return bool(RIME_FILE.fullmatch(name)) or name in (MOZC_FILE, WORDS_FILE)


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
SYNC_DICTIONARY = "SebType sync"  # where words from other devices go


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


def mozc_text(words):
    """Mozc's export format, sorted so an unchanged dictionary uploads nothing."""
    lines = (
        "\t".join([r, w, POS[p]] + ([c] if c else [])) + "\n" for r, w, p, c in words
    )
    return "".join(sorted(lines)).encode()


def parse_mozc_text(data):
    words = set()
    for line in data.decode("utf-8", "replace").lstrip("\ufeff").splitlines():
        f = line.split("\t")
        if len(f) >= 3 and f[0] and f[1] and not line.startswith("#"):
            words.add((f[0], f[1], POS.index(f[2]) if f[2] in POS else NOUN))
    return words


def mozc_add(db, words):
    """db with words added to its SebType sync dictionary, made if missing; the rest kept unchanged."""
    entries = b"".join(
        pb_field(4, pb_field(1, r) + pb_field(2, w) + pb_field(5, p))
        for r, w, p in words
    )
    out = bytearray()
    for number, dictionary, start, end in pb_fields(db):
        d = {n: v for n, v, _, _ in pb_fields(dictionary)} if number == 2 else {}
        if entries and d.get(3) == SYNC_DICTIONARY.encode() and not d.get(5):
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
            + pb_field(3, SYNC_DICTIONARY)
            + entries,
        )
    return bytes(out)


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
    """Mozc saves its dictionary by renaming a new file over it, so a read needs no lock."""
    try:
        with open(db_path, "rb") as f:
            return f.read()
    except FileNotFoundError:  # no word registered yet
        return b""


def mozc_take_in(db_path, new, old):
    """Adds the words another device's Mozc file gained since its previous copy, and that this
    dictionary lacks, to Mozc's dictionary; returns how many."""
    with mozc_lock(db_path):
        db = read_mozc(db_path)
        have = {(r, w, p) for r, w, p, _ in mozc_words(db)}
        words = sorted(parse_mozc_text(new) - parse_mozc_text(old or b"") - have)
        if words:
            if db:
                shutil.copyfile(db_path, db_path + ".sebtype-backup")
            write_file(db_path, mozc_add(db, words))
        return len(words)


# --- PC client: pull and push ---


def write_file(path, body):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
    with os.fdopen(fd, "wb") as out:
        out.write(body)
    os.replace(tmp, path)


def pull(client, device, sync_dir, mozc_db=None):
    """Downloads every other device's changed files into sync_dir/<device>/, and with mozc_db adds
    their new Japanese words to Mozc; returns (files, words)."""
    count = words = 0
    for f in client.files():
        name = f["name"]
        # The copy kept of a Mozc file is what its next download is compared with: it is taken only
        # along with its words. Nothing on a PC uses another device's English words.
        if (
            f["device"] == device
            or not (NAME.fullmatch(f["device"]) and synced(name))
            or name == WORDS_FILE
            or (name == MOZC_FILE and not mozc_db)
        ):
            continue
        path = os.path.join(sync_dir, f["device"], name)
        old = None
        if os.path.isfile(path):
            with open(path, "rb") as fh:
                old = fh.read()
            if hashlib.sha256(old).hexdigest() == f["sha256"]:
                continue
        body = client.request("GET", f"/v1/files/{f['device']}/{name}")
        if name == MOZC_FILE:
            words += mozc_take_in(mozc_db, body, old)
        write_file(path, body)
        count += 1
    return count, words


def push(client, device, sync_dir, mozc_db=None):
    """Uploads this device's changed snapshots (learned words, not Rime's yaml backups) and with
    mozc_db its Japanese dictionary; returns how many."""
    remote = {f["name"]: f["sha256"] for f in client.files() if f["device"] == device}
    files = {}
    folder = os.path.join(sync_dir, device)
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if RIME_FILE.fullmatch(name):
            with open(os.path.join(folder, name), "rb") as f:
                files[name] = f.read()
    if mozc_db:
        files[MOZC_FILE] = mozc_text(mozc_words(read_mozc(mozc_db)))
    count = 0
    for name, body in files.items():
        if remote.get(name) != hashlib.sha256(body).hexdigest():
            client.request("PUT", f"/v1/files/{device}/{name}", body)
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
            files, words = pull(client, device, sync_dir, args.mozc_db)
            print(f"pull: {files} file(s), {words} new word(s) for Mozc")
        else:
            print(f"push: {push(client, device, sync_dir, args.mozc_db)} file(s)")
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
