# Mozc's learned conversions sync (#409), in a private Fcitx5 this script starts, through a local sebtype_sync.py
# server (pc/configurator/test.sh's private-learned-sync, inside its private D-Bus session and sandbox):
#   python3 test-learned-sync.py <out> <configurator tests executable> <configurator>
# with SEBTYPE_TEST_SYNC_SERVER, _USER and _PASSWORD set. This PC picks a conversion and a made-up phone, on the
# server, picks others; the Configurator's --sync takes each to the other. Checked: each device gets the other's;
# the same reading picked on both comes first as the later pick; learning off (--learning off) records nothing
# new but still learns the phone's; Forget (--forget ja) empties this PC's record, which the next sync uploads
# so, and what the phone picked before doesn't come back after a sync, only what it picks after. A pick written as
# it reads is recorded too.
# Results: one line per check, also in <out>/learned-sync-results.txt; exit 1 if a check fails.
import base64
import json
import os
import subprocess
import sys
import time
import urllib.request

from private_fcitx import Fcitx

out, tests, app = sys.argv[1:4]
server, user, password = (
    os.environ[f"SEBTYPE_TEST_SYNC_{n}"] for n in ("SERVER", "USER", "PASSWORD")
)
mozc = f"{os.environ['XDG_CONFIG_HOME']}/mozc"
own = f"{mozc}/mozc_learned.txt"
PHONE = "sebtype-test-phone"
HEADER = "# SebType mozc_learned 1\n"
failed = 0


def result(name, ok, why):
    global failed
    failed += not ok
    line = f"{'PASS' if ok else 'FAIL'} {name}: {why}"
    print(line, flush=True)
    with open(f"{out}/learned-sync-results.txt", "a") as f:
        f.write(line + "\n")


def http(method, path, body=None):
    req = urllib.request.Request(server + path, data=body, method=method)
    req.add_header(
        "Authorization",
        "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode(),
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read()


phone = {}  # the phone's record: (reading, written) -> time


def phone_picks(reading, written, time_):
    phone[(reading, written)] = time_
    body = HEADER + "".join(
        f"{k}\t{v}\t{t}\n" for (k, v), t in sorted(phone.items(), key=lambda p: p[1])
    )
    http("PUT", f"/v1/files/{PHONE}/mozc_learned.txt", body.encode())


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except FileNotFoundError:
        return ""


def pc_on_server():
    names = [
        (f["device"], f["name"]) for f in json.loads(http("GET", "/v1/files"))["files"]
    ]
    pc = next((d for d, n in names if n == "mozc_learned.txt" and d != PHONE), None)
    return http("GET", f"/v1/files/{pc}/mozc_learned.txt").decode() if pc else ""


def configurator(*args):
    r = subprocess.run(
        [app, *args], check=False, capture_output=True, text=True, timeout=120
    )
    with open(f"{out}/learned-sync-configurator.log", "a") as log:
        log.write(f"$ {' '.join(args)}: exit {r.returncode}\n{r.stdout}{r.stderr}")
    return r.returncode == 0


def sync():
    """The Configurator's sync; once it pulled the phone's record, Mozc restarts when typing is idle and learns it:
    done when its copy as learned is the record."""
    if not configurator("--sync"):
        return False
    record = f"{mozc}/mozc_learned/{PHONE}"
    for _ in range(120):
        if read(record + ".txt") and read(record + ".applied") == read(record + ".txt"):
            return True
        time.sleep(0.5)
    return False


# Readings whose first candidate a pick can change, and what the phone picks for them: Mozc's candidates.
KISHA, KANJI, TOUKI, SEIKA = "kisha", "kanji", "touki", "seika"
READING = {KISHA: "きしゃ", KANJI: "かんじ", TOUKI: "とうき", SEIKA: "せいか"}
PHONE_PICK = {KISHA: "汽車", KANJI: "幹事", TOUKI: "冬季", SEIKA: "聖火"}

login = subprocess.run(
    [tests, "--ignored", "--exact", "sync::tests::private_login"],
    check=False,
    capture_output=True,
    timeout=60,
)
f = Fcitx(f"{out}/learned-sync-fcitx5.log")
# A sync also writes 中文's snapshot, which Rime makes once 中文 is in use.
ready = login.returncode == 0 and f.language("zh") and f.language("ja")
first = {
    w: f.type(w + " \n") for w in READING
}  # committing the first candidate learns no pick
result(
    "ja-ready",
    ready and all(first.values()) and all(first[w] != PHONE_PICK[w] for w in READING),
    f"login exit {login.returncode}, first candidates {first}, none the phone's {PHONE_PICK}",
)

# This PC picks the 4th candidate for きしゃ; the phone picked 汽車 for it earlier, and 幹事 for かんじ.
picked = f.type(KISHA + "    \n")
again = f.type(KISHA + " \n")
recorded = f"きしゃ\t{picked}\t" in read(own)
result(
    "pc-learns-and-records",
    picked not in ("", first[KISHA], PHONE_PICK[KISHA])
    and again == picked
    and recorded,
    f"4th '{picked}', then first '{again}', {'in' if recorded else 'not in'} {own}",
)
now = int(time.time())
phone_picks(READING[KISHA], PHONE_PICK[KISHA], now - 100)
phone_picks(READING[KANJI], PHONE_PICK[KANJI], now - 50)
synced = sync()
uploaded = pc_on_server()
result(
    "pc-pick-reaches-server",
    synced and uploaded.startswith(HEADER) and f"きしゃ\t{picked}\t" in uploaded,
    f"{'synced' if synced else 'no sync'}, the PC's record on the server: {uploaded!r}",
)
now_kanji, now_kisha = f.type(KANJI + " \n"), f.type(KISHA + " \n")
result(
    "phone-pick-reaches-pc",
    now_kanji == PHONE_PICK[KANJI],
    f"かんじ first '{now_kanji}'",
)
result(
    "same-reading-later-pick-first",
    now_kisha == picked,
    f"きしゃ first '{now_kisha}': this PC's pick, later than the phone's {PHONE_PICK[KISHA]}",
)

# The phone picks 汽車 again, later than this PC: it comes first here too.
phone_picks(READING[KISHA], PHONE_PICK[KISHA], int(time.time()) + 10)
synced = sync()
now_kisha = f.type(KISHA + " \n")
result(
    "same-reading-phone-later-first",
    synced and now_kisha == PHONE_PICK[KISHA],
    f"{'synced' if synced else 'no sync'}, きしゃ first '{now_kisha}'",
)

# Learning off: a pick here is neither learned nor recorded; the phone's new pick is still learned.
before = read(own)
off = configurator("--learning", "off")
picked_off = f.type(SEIKA + "   \n")
now_seika = f.type(SEIKA + " \n")
result(
    "learning-off-records-nothing",
    off
    and picked_off not in ("", first[SEIKA])
    and now_seika == first[SEIKA]
    and read(own) == before,
    f"3rd '{picked_off}', then first '{now_seika}', record {'unchanged' if read(own) == before else 'changed'}",
)
phone_picks(READING[TOUKI], PHONE_PICK[TOUKI], int(time.time()) + 20)
synced = sync()
now_touki = f.type(TOUKI + " \n")
result(
    "learning-off-still-learns-phone",
    synced and now_touki == PHONE_PICK[TOUKI],
    f"{'synced' if synced else 'no sync'}, とうき first '{now_touki}'",
)
on = configurator("--learning", "on")

# A pick written as it reads, せいか over 成果 (seika's 3rd candidate, as above), is recorded too (#415 review).
picked_kana = f.type(SEIKA + "   \n")
recorded = f"{READING[SEIKA]}\t{READING[SEIKA]}\t" in read(own)
result(
    "kana-pick-recorded",
    on and picked_kana == READING[SEIKA] and recorded,
    f"3rd '{picked_kana}', {'in' if recorded else 'not in'} the record",
)

# Forget: this PC's record is emptied and uploaded so; the phone's earlier picks don't come back after a sync,
# its later one does.
forgot = configurator("--forget", "ja")
emptied = read(own) == HEADER
back = {w: f.type(w + " \n") for w in (KISHA, KANJI, TOUKI)}
result(
    "forget-clears-record",
    on and forgot and emptied and back == {w: first[w] for w in back},
    f"record {'empty' if emptied else repr(read(own))}, first {back}, want { ({w: first[w] for w in back}) }",
)
synced = sync()
uploaded = pc_on_server()
back = {w: f.type(w + " \n") for w in (KISHA, KANJI, TOUKI)}
result(
    "forget-stays-after-sync",
    synced and uploaded == HEADER and back == {w: first[w] for w in back},
    f"the PC's record on the server {uploaded!r}, first {back}",
)
phone_picks(READING[SEIKA], PHONE_PICK[SEIKA], int(time.time()) + 30)
synced = sync()
now_seika, now_kanji = f.type(SEIKA + " \n"), f.type(KANJI + " \n")
result(
    "phone-picks-after-forget-come",
    synced and now_seika == PHONE_PICK[SEIKA] and now_kanji == first[KANJI],
    f"せいか first '{now_seika}', かんじ first '{now_kanji}' (forgotten)",
)
f.stop()
sys.exit(1 if failed else 0)
