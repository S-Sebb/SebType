#!/usr/bin/env python3
"""SebType's sync server and its PC client (#12): a self-hostable home for Rime's sync folders.

Rime syncs learned words through a folder, `sync/<installation id>/`: every device writes only its own
folder and merges in everyone else's, so a server that keeps one copy of each device's folder per user
is all sync needs (study report on #3, section 6). The server stores the `*.userdb.txt` files and the
phone's crash reports (#33) and nothing else, behind its own usernames and passwords (scrypt-hashed in users.json). It speaks plain
HTTP on 127.0.0.1 by default: put an HTTPS reverse proxy in front of it, or give it a certificate.

    sebtype_sync.py serve   --data DIR [--host H] [--port P] [--tls-cert F --tls-key F]
    sebtype_sync.py adduser --data DIR NAME [--password-stdin]
    sebtype_sync.py deluser --data DIR NAME          (also deletes the user's files and crash reports)
    sebtype_sync.py pull|push --server URL --user NAME --password-file F --rime-dir DIR

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
FILE = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.userdb\.txt")
MAX_FILE = 64 << 20  # a userdb snapshot of years of typing is a few MB
CRASH = re.compile(r"crash-\d{8}-\d{6}-[0-9a-f]{6}\.txt")
MAX_CRASH = 256 << 10  # a report is a stack trace and 200 log lines, a few dozen KB
SCRYPT = {"n": 1 << 14, "r": 8, "p": 1}


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
            if NAME.fullmatch(device) and FILE.fullmatch(name):
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
                    if FILE.fullmatch(name):  # not an upload in progress
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


# --- PC client: Rime's sync folder <-> the server ---


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


def pull(client, device, sync_dir):
    """Downloads every other device's changed files into sync_dir/<device>/; returns how many."""
    count = 0
    for f in client.files():
        if f["device"] == device or not (
            NAME.fullmatch(f["device"]) and FILE.fullmatch(f["name"])
        ):
            continue
        path = os.path.join(sync_dir, f["device"], f["name"])
        if os.path.isfile(path) and sha256_of(path) == f["sha256"]:
            continue
        body = client.request("GET", f"/v1/files/{f['device']}/{f['name']}")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path))
        with os.fdopen(fd, "wb") as out:
            out.write(body)
        os.replace(tmp, path)
        count += 1
    return count


def push(client, device, sync_dir):
    """Uploads this device's changed snapshots (learned words only, not Rime's yaml backups); returns how many."""
    remote = {f["name"]: f["sha256"] for f in client.files() if f["device"] == device}
    folder = os.path.join(sync_dir, device)
    count = 0
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        path = os.path.join(folder, name)
        if FILE.fullmatch(name) and remote.get(name) != sha256_of(path):
            with open(path, "rb") as f:
                client.request("PUT", f"/v1/files/{device}/{name}", f.read())
            count += 1
    return count


def run_client(args):
    with open(args.password_file, encoding="utf-8") as f:
        password = f.read().strip()
    device, sync_dir = rime_installation(args.rime_dir)
    client = Client(args.server, args.user, password)
    try:
        n = (pull if args.command == "pull" else push)(client, device, sync_dir)
    except urllib.error.HTTPError as e:
        sys.exit(f"{args.command}: the server said {e.code}")
    except OSError as e:
        sys.exit(f"{args.command}: can't reach the server ({type(e).__name__})")
    print(f"{args.command}: {n} file(s)")


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
    for command in ("pull", "push"):
        c = sub.add_parser(command)
        c.add_argument("--server", required=True)
        c.add_argument("--user", required=True)
        c.add_argument("--password-file", required=True)
        c.add_argument(
            "--rime-dir", required=True, help="Rime's user dir, with installation.yaml"
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
