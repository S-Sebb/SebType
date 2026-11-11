#!/usr/bin/env python3
"""Settings checks on the emulator (#41), run by sebtype/test-emulator.sh under the emulator lock after
test-chinese.py, which leaves SebType installed, chosen as the keyboard and Chinese set up.

    test-settings.py SERIAL RESULTS LOGDIR

Opens every settings screen from the home screen (one screenshot each, settings-<screen>.png in
LOGDIR), then checks that SebType's own options take effect while typing: the globe order, Chinese
full-width punctuation, emoji among Chinese candidates, Chinese "My words", and forgetting learned
words in Chinese and Japanese; that Picnic is the only look, with no theme choice anywhere and the
same look in the system's dark mode (#111); that FUTO's payment screen and its row in About carry
SebType's licence note (#112). Last, that long lists (300 of My words, the credits) scroll smoothly
in their pixel-framed cards on the cloth (#87). Then, with the system switched to 日本語 and back to en-US after,
that every screen shows no English SebType string (#120, settings-ja-*.png in LOGDIR). Then incognito (#31):
password and private fields and the sticky toggle learn nothing in English, 中文 and 日本語 and keep no
clipboard copy, but still offer what was learned before; the toggle survives a restart, and turned off,
learning resumes. Then sync with a local sync-server (#12, made-up login and words): offline a learned
word stays on the phone, back online a keyboard hide uploads it, a word in another device's folder on
the server is offered after a sync, the login is in no log or plain file, and the delete button empties
the server. Last, that a settings backup leaves clipboard history out unless its box is ticked,
and that importing restores it (#34), with the backup screen's screenshot in English and Japanese
(settings-backup-<locale>.png). Labels match the emulator's Chinese, English or Japanese UI. One line
per check appended to RESULTS; each check finds its own way from the home screen, so one failing
doesn't stop the next.
"""

import functools
import glob
import os
import re
import shutil
import socket
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

serial, results_path, logdir = sys.argv[1:4]
# Only the checks whose names start with one of SEBTYPE_CHECKS (comma-separated, as test-emulator.sh takes it).
CHECKS = [c for c in os.environ.get("SEBTYPE_CHECKS", "").split(",") if c]
# Timing checks run only in the final performance run (#54, Decisions #2 2026-11-11): PERF_RUN=1.
TIMING = {"settings-smooth-scrolling"}
PKG = "dev.sebb.sebtype"
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
SETTINGS = f"{PKG}/org.futo.inputmethod.latin.uix.settings.SettingsActivity"
FIELD = "dev.sebb.sebtype.perffield/.PerfField"
PREPARING = ("正在准备中文", "Preparing Chinese")
NOT_CANDIDATES = (*PREPARING, "中文输入启动失败", "Chinese input failed")
log_path = os.path.join(logdir, "test-settings.log")
# Seconds for the keyboard to come up. It restarts often here, and while the other emulator runs a
# suite (#103) a restart has taken over 30 s; how fast it comes up is perf.sh's to measure.
KEYBOARD_WAIT = 60


def adb(*args, timeout=120, check=True):
    p = subprocess.run(
        ["adb", "-s", serial, *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(f"$ adb {' '.join(args)}\n{p.stdout[-2000:]}{p.stderr[-2000:]}\n")
    if check and p.returncode != 0:
        raise RuntimeError(
            f"adb {' '.join(args)} failed: {p.stderr.strip() or p.stdout.strip()}"
        )
    return p.stdout


def result(status, name, detail=""):
    line = f"{status} {name}" + (f": {detail}" if detail else "")
    print(line, flush=True)
    with open(results_path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


class Fail(Exception):
    pass


class Skip(Exception):
    pass


def wait_for(what, fn, timeout, interval=1.0):
    end = time.time() + timeout
    while True:
        value = fn()
        if value:
            return value
        if time.time() > end:
            raise Fail(f"timed out after {timeout}s waiting for {what}")
        time.sleep(interval)


def tap(x, y):
    adb("shell", "input", "tap", str(x), str(y))


# --- The keyboard (as in test-chinese.py) ---

keyboard_frame = None
BAR_CONTROLS = (
    set()
)  # the suggestion bar's own buttons, filled in with their labels below


def nodes():
    """(label, x, y, top, class) of every node in all windows, keyboard included."""
    global keyboard_frame
    adb("shell", "uiautomator", "dump", "--windows", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    out, frame = [], None
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        label = n.get("text") or n.get("content-desc") or ""
        m = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", n.get("bounds", ""))
        if m:
            x1, y1, x2, y2 = map(int, m.groups())
            out.append((label, (x1 + x2) // 2, (y1 + y2) // 2, y1, n.get("class")))
            if n.get("resource-id") == f"{PKG}:id/main_keyboard_frame":
                frame = keyboard_frame = (x1, y1, x2, y2)
    if frame and not keys(out):
        out += letter_keys(*frame)
    return out


def letter_keys(left, top, right, bottom):
    w, h = (right - left) / 10, (bottom - top) / 4
    rows = (("qwertyuiop", 0.5), ("asdfghjkl", 1), ("zxcvbnm", 2))
    return [
        (
            ch,
            int(left + (i + indent) * w),
            int(top + (r + 0.5) * h),
            int(top + r * h),
            "key",
        )
        for r, (letters, indent) in enumerate(rows)
        for i, ch in enumerate(letters)
    ]


def keys(ns):
    return {
        label: (x, y, top)
        for label, x, y, top, cls in ns
        if re.fullmatch(r"[a-z]", label)
    }


def bottom_key(column):
    """A bottom-row key by its centre, in tenths of the keyboard's width: the globe sits at 3, the
    Chinese layout's 。 key at 8 (symbols 1.5, ， 1, globe 1, space 4, 。 1, enter 1.5)."""
    left, top, right, bottom = keyboard_frame
    tap(int(left + column * (right - left) / 10), int(top + 3.5 * (bottom - top) / 4))


def candidates(ns):
    k = keys(ns)
    if "q" not in k:
        return []
    row = (k["q"][2] - 130, k["q"][2])
    bar = [
        (x, label)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1]
        and cls == "android.widget.TextView"
        and label
        and not label.startswith(NOT_CANDIDATES)
        and label not in ("あ", "ア")
    ]
    return [label for x, label in sorted(bar)]


def en_candidates(ns):
    """English's suggestions, left to right: the bar's labelled nodes of any class, but its buttons."""
    k = keys(ns)
    if "q" not in k:
        return []
    row = (k["q"][2] - 130, k["q"][2])
    controls = {"あ", "ア", *BAR_CONTROLS}
    bar = {
        (x, label)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1] and label and label not in controls
    }
    return [label for x, label in sorted(bar)]


def expanded_candidates():
    ns = nodes()
    k = keys(ns)
    row = (k["q"][2] - 130, k["q"][2])
    button = max(
        (x, y)
        for label, x, y, top, cls in ns
        if row[0] < y < row[1] and cls == "android.widget.Button"
    )
    tap(*button)
    time.sleep(1.5)
    grid = [
        (top, x, label)
        for label, x, y, top, cls in nodes()
        if y > row[1] and cls == "android.widget.TextView" and label
    ]
    return [label for top, x, label in sorted(grid)]


def type_keys(text):
    k = wait_for("the keyboard", lambda: keys(nodes()), KEYBOARD_WAIT)
    for ch in text:
        tap(k[ch][0], k[ch][1])
    time.sleep(1.5)


def open_field(kind=None, clip=None):
    """A new text field with SebType up; kind makes it a password or private field, clip a text the
    field app copies to the clipboard a moment after it opens (sebtype/perf/PerfField.java)."""
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "ime", "set", IME)
    # A slow emulator can show "System UI isn't responding" over everything; this closes it.
    adb("shell", "am", "broadcast", "-a", "android.intent.action.CLOSE_SYSTEM_DIALOGS")
    extra = (["--es", "kind", kind] if kind else []) + (
        ["--es", "clip", clip] if clip else []
    )
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", FIELD, *extra)
    wait_for("the keyboard", lambda: keys(nodes()), KEYBOARD_WAIT)


def candidates_for(text, expand=False, kind=None):
    open_field(kind)
    type_keys(text)
    got = wait_for(f"candidates for {text}", lambda: candidates(nodes()), 60)
    if expand:
        got += [c for c in expanded_candidates() if c not in got]
    return got


def field_text():
    return next((n[0] for n in nodes() if n[4] == "android.widget.EditText"), "")


def tap_candidate(word):
    for label, x, y, top, cls in nodes():
        if label == word:
            tap(x, y)
            time.sleep(1.5)
            return
    raise Fail(f"{word} not in the candidate bar")


def to_language(probe, word):
    """Cycles the globe until typing probe offers word (中: ni -> 你, 日: nihongo -> 日本語, English:
    hello -> Hello, capitalised at the field's start, with no Chinese or Japanese among the candidates,
    as 中 and 日 offer hello among their own words)."""
    for _ in range(8):
        try:
            open_field()
            type_keys(probe)
            # Chinese sets itself up the first time it comes up, showing its notice meanwhile.
            end = time.time() + 300
            # A language that has just come up can take a moment before its first candidates.
            first = time.time() + 15
            while True:
                ns = nodes()
                if probe == "hello":  # English's words aren't TextViews: en_candidates
                    got = en_candidates(ns)
                    english = not any(
                        re.search(r"[\u3040-\u30ff\u4e00-\u9fff]", c) for c in got
                    )
                else:
                    got, english = candidates(ns), True
                if english and word in [c.lower() for c in got]:
                    return
                preparing = any(n[0].startswith(PREPARING) for n in ns)
                waiting = preparing or (not got and time.time() < first)
                if not waiting or time.time() > end:
                    break
                time.sleep(3)
            open_field()
            bottom_key(3)
            time.sleep(2)
        except Fail:
            # Mozc can crash when Japanese starts on the emulator (#35); a restart brings it back.
            adb("shell", "am", "force-stop", PKG)
    raise Fail(f"no language offers {word} for {probe}")


# --- The settings app ---


def labels(*texts):
    return texts


HOME = {
    "languages": labels("语言", "Languages", "言語"),
    "keyboard": labels("键盘", "Keyboard", "キーボード"),
    "privacy": labels("隐私", "Privacy", "プライバシー"),
    "backup": labels("同步与备份", "Sync & backup", "同期とバックアップ"),
    "about": labels("关于", "About", "情報"),
}
MY_WORDS = labels("我的词语", "My words", "自分の単語")
FULL_WIDTH = labels("全角标点", "Full-width punctuation")
EMOJI = labels("候选词中显示表情", "Emoji in candidates")


def find_all(ns, texts):
    return sorted(
        (
            (y, x)
            for label, x, y, top, cls in ns
            if any(
                label == t or label.startswith((t + ".", t + ",", t + "\n"))
                for t in texts
            )
        )
    )


def screen_has(texts):
    return bool(find_all(nodes(), texts))


def tap_text(texts, nth=0):
    """Taps the nth node (top to bottom) showing one of texts, scrolling down until it shows."""
    for _ in range(6):
        found = find_all(nodes(), texts)
        if len(found) > nth:
            y, x = found[nth]
            tap(x, y)
            time.sleep(1.5)
            return
        adb("shell", "input", "swipe", "540", "1900", "540", "900", "400")
        time.sleep(1)
    raise Fail(f"no {texts[0]} on the screen")


def open_settings():
    # A new task each time, so it opens on the home screen. Without SebType chosen as the keyboard
    # the app opens on its setup screen instead.
    adb("shell", "ime", "set", IME)
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", SETTINGS)
    wait_for("the settings home screen", home_shown, 30)


def home_shown():
    if screen_has(HOME["about"]):
        return True
    # Just after SebType restarts the system can fall back to another keyboard; choosing SebType again
    # takes the setup screen on to the home screen.
    adb("shell", "ime", "set", IME)
    return False


def go(*path):
    """From a fresh home screen, follows path: label tuples, or (labels, nth) for a repeated one."""
    open_settings()
    for step in path:
        texts, nth = step if isinstance(step[1], int) else (step, 0)
        tap_text(texts, nth)


def screenshot(name):
    adb("shell", "screencap -p /sdcard/sebtype-shot.png")
    adb(
        "pull", "/sdcard/sebtype-shot.png", os.path.join(logdir, f"settings-{name}.png")
    )


def toggle(path, texts):
    go(*path)
    tap_text(texts)


def check(name, fn):
    if CHECKS and not any(name.startswith(c) for c in CHECKS):
        return
    if name in TIMING and not os.environ.get("PERF_RUN"):
        if CHECKS:  # named, so say why it didn't run
            result("SKIP", name, "timing check, runs only with PERF_RUN=1 (#54)")
        return
    try:
        detail = fn()
        result("PASS", name, detail or "")
    except Skip as e:
        result("SKIP", name, str(e))
    except (
        Fail,
        RuntimeError,
        subprocess.SubprocessError,
        ET.ParseError,
        LookupError,
        ValueError,
    ) as e:
        result("FAIL", name, str(e))


# Every screen: how to get there from home, and a text only it shows.
LANG = HOME["languages"]
SCREENS = [
    ("home", (), labels("同步与备份", "Sync & backup", "同期とバックアップ")),
    ("languages", (LANG,), labels("地球键顺序", "Globe order", "地球キーの順番")),
    (
        "en-words",
        (LANG, (MY_WORDS, 0)),
        labels("添加", '"添加"', "Add", "Words", "词语", '"追加"', "追加", "単語"),
    ),
    (
        "zh-fuzzy",
        (LANG, labels("Fuzzy Pinyin", "模糊拼音", "あいまいピンイン")),
        labels("zh=z", "zh = z", "z=zh", "z = zh", "zh, ch, sh"),
    ),
    (
        "zh-words",
        (LANG, (MY_WORDS, 1)),
        labels("还没有词语", "No words yet", "単語はまだありません"),
    ),
    (
        "ja-words",
        (LANG, (MY_WORDS, 2)),
        labels("添加", '"添加"', "Add", "Words", "词语", '"追加"', "追加", "単語"),
    ),
    (
        "keyboard",
        (HOME["keyboard"],),
        labels("尺寸和位置", "Size and position", "サイズと位置"),
    ),
    (
        "resize",
        (HOME["keyboard"], labels("尺寸和位置", "Size and position", "サイズと位置")),
        labels("调整键盘大小", "Resize Keyboard", "キーボードサイズ調整"),
    ),
    (
        "action-bar",
        (
            HOME["keyboard"],
            labels("操作栏按钮", "Action bar buttons", "アクションバーのボタン"),
        ),
        labels("编辑快捷方式", "Edit Actions", "アクションの編集"),
    ),
    (
        "privacy",
        (HOME["privacy"],),
        labels("从我的输入中学习", "Learn from my typing", "入力から学習"),
    ),
    (
        "forget",
        (
            HOME["privacy"],
            labels("忘记学到的词", "Forget learned words", "学習した単語を消去"),
        ),
        labels("忘记", "Forget", "消去"),
    ),
    (
        "backup",
        (HOME["backup"],),
        labels("导出设置", "Export settings", "設定をエクスポート"),
    ),
    ("about", (HOME["about"],), labels("版本", "Version", "バージョン")),
    (
        "credits",
        (
            HOME["about"],
            labels("许可与致谢", "Licence and credits", "ライセンスとクレジット"),
        ),
        labels("Credits", "致谢", "クレジット"),
    ),
    (
        "payment",
        (HOME["about"], labels("支持 FUTO", "Support FUTO", "FUTO を支援")),
        labels("为FUTO Keyboard支付", "Pay for FUTO Keyboard", "FUTO キーボードの購入"),
    ),
]


def every_screen():
    opened = []
    failed = []
    for name, path, marker in SCREENS:
        try:
            go(*path)
            wait_for(
                f"{name} ({marker[0]})", lambda marker=marker: screen_has(marker), 10
            )
            screenshot(name)
            opened.append(name)
        except Fail as e:
            screenshot(name)
            failed.append(f"{name}: {e}")
    if failed:
        raise Fail("; ".join(failed))
    return f"{len(opened)} screens: {', '.join(opened)}"


def home_order():
    open_settings()
    return next(
        (
            label
            for label, *_ in nodes()
            if re.search(r"EN|中|日", label) and "→" in label
        ),
        "",
    )


def drag_globe_row(src, dst):
    """Drags language row src's handle onto row dst's place (rows 0..2 in the globe order list)."""
    go(LANG)
    rows = find_all(nodes(), labels("拖动以排序", "Drag to reorder"))
    if len(rows) < 3:
        raise Fail(f"{len(rows)} drag handles on the languages screen")
    (y1, _), (y2, _) = rows[src], rows[dst]
    # The handle's label merges into its row's, so this node is the row; the handle is its icon, in
    # the first tenth of the screen's width.
    width = int(re.search(r"(\d+)x\d+", adb("shell", "wm", "size")).group(1))
    x = width // 10
    adb(
        "shell",
        "input",
        "swipe",
        str(x),
        str(y1),
        str(x),
        str(y2 + (8 if y2 > y1 else -8)),
        "1500",
    )
    time.sleep(1.5)


def globe_order():
    before = home_order()
    drag_globe_row(2, 1)
    after = home_order()
    drag_globe_row(2, 1)
    restored = home_order()
    if not before or after == before or restored != before:
        raise Fail(
            f"home summary {before!r}, after dragging 日 up {after!r}, after dragging back {restored!r}"
        )
    return f"{before} -> {after} -> {restored}"


def punctuation_typed():
    open_field()
    bottom_key(8)
    time.sleep(1.5)
    return field_text()


def full_width_punctuation():
    to_language("ni", "你")
    on = punctuation_typed()
    toggle((LANG,), FULL_WIDTH)
    to_language("ni", "你")
    off = punctuation_typed()
    toggle((LANG,), FULL_WIDTH)
    to_language("ni", "你")
    again = punctuation_typed()
    if (on, off, again) != ("。", ".", "。"):
        raise Fail(f"the 。 key typed {on!r} on, {off!r} off, {again!r} on again")
    return "the 。 key types 。 with it on, . with it off"


def is_emoji(text):
    return any(0x1F300 <= ord(c) <= 0x1FAFF or 0x2600 <= ord(c) <= 0x27BF for c in text)


def emoji_candidates():
    to_language("ni", "你")
    on = [c for c in candidates_for("xiao", expand=True) if is_emoji(c)]
    toggle((LANG,), EMOJI)
    to_language("ni", "你")
    off = [c for c in candidates_for("xiao", expand=True) if is_emoji(c)]
    toggle((LANG,), EMOJI)
    if not on or off:
        raise Fail(f"emoji for xiao: {on} on, {off} off")
    return f"xiao offers {on[:3]} with it on, none off"


@functools.cache
def install_set_text():
    """Builds and installs sebtype/set-text, once per run (run from the repo root)."""
    apk = os.path.join(logdir, "set-text.apk")
    subprocess.run(["sebtype/set-text/build.sh", apk], check=True, capture_output=True)
    adb("install", "-r", apk)


def set_text(index, text):
    """Sets the active window's index-th text field through accessibility, with no keyboard."""
    install_set_text()
    out = adb(
        "shell",
        "am",
        "instrument",
        "-w",
        "-e",
        "index",
        str(index),
        "-e",
        "text",
        text,
        "dev.sebb.sebtype.settext/.SetText",
    )
    if "result=set" not in out:
        raise Fail(f"couldn't set field {index} to {text}: {out.strip()[-300:]}")


def add_my_word(word, pinyin):
    go(LANG, (MY_WORDS, 1))
    tap_text(labels("添加", '"添加"', "Add"))
    set_text(0, word)
    set_text(1, pinyin)
    tap_text(labels("保存", "Save"))


def my_words():
    to_language("ni", "你")
    add_my_word("sebword", "qqzz")
    first = candidates_for("qqzz")[:3]
    go(LANG, (MY_WORDS, 1))
    tap_text(labels("sebword"))
    tap_text(labels("删除", "Delete"))
    time.sleep(2)
    gone = candidates_for("qqzz")[:3]
    if not first or first[0] != "sebword" or "sebword" in gone:
        raise Fail(f"qqzz -> {first} with the word added, {gone} after deleting it")
    return f"qqzz -> {first} with sebword added, {gone} after deleting it"


def forget(language):
    go(
        HOME["privacy"],
        labels("忘记学到的词", "Forget learned words", "学習した単語を消去"),
    )
    tap_text(language)
    found = find_all(nodes(), labels("忘记", "Forget", "消去"))
    y, x = found[-1]  # the dialog's button, below the dialog title
    tap(x, y)
    time.sleep(3)


def forget_chinese():
    to_language("ni", "你")
    got = candidates_for("lh", expand=True)
    if got[0] != "厉害":
        tap_candidate("厉害")
    learned = candidates_for("lh")[:3]
    forget(labels("中文"))
    after = candidates_for("lh")[:3]
    if learned[0] != "厉害" or after[0] == "厉害":
        raise Fail(f"lh -> {learned} learned, {after} after forgetting")
    return f"lh -> {learned} learned, {after} after forgetting 中文"


def forget_japanese():
    to_language("nihongo", "日本語")
    fresh = candidates_for("kaku")
    pick = fresh[1]
    tap_candidate(pick)
    learned = candidates_for("kaku")[:3]
    forget(labels("日本語"))
    to_language("nihongo", "日本語")
    after = candidates_for("kaku")[:3]
    if learned[0] != pick or after[0] != fresh[0]:
        raise Fail(
            f"kaku -> {fresh[:3]}, {learned} after picking {pick}, {after} after forgetting"
        )
    return f"kaku -> {fresh[:3]}, {learned} after picking {pick}, {after} after forgetting 日本語"


WORDS_FILE = f"/data/data/{PKG}/files/rime/user/custom_phrase.txt"
# Most janky %, slowest p90 (ms) per list, from the plain one-colour look on guide35, which renders
# in software (2026-11-10): My words 1.6 %, 16 ms; credits, laid out whole, 30-39 %, 48-57 ms. The
# limits leave room for the cloth and frames, not for a drawing cost per row: a rect per dash in
# the dividers made My words 27.5 %, 53 ms. System Settings is 53-70 % janky on this emulator.
SMOOTH_LIMITS = {"zh-words-300": (10, 45), "credits": (45, 70)}


def root(cmd):
    return adb("shell", f"su 0 sh -c '{cmd}'")


def fling_stats(name, path):
    """Opens path, flings down through it, and returns the app's frame stats for the flings."""
    go(*path)
    size = re.search(r"(\d+)x(\d+)", adb("shell", "wm", "size"))
    w, h = int(size[1]), int(size[2])
    adb("shell", "dumpsys", "gfxinfo", PKG, "reset")
    for _ in range(8):
        adb(
            "shell",
            "input",
            "swipe",
            str(w // 2),
            str(h * 4 // 5),
            str(w // 2),
            str(h // 5),
            "150",
        )
        time.sleep(1)
    info = adb("shell", "dumpsys", "gfxinfo", PKG)
    frames = int(re.search(r"Total frames rendered: (\d+)", info)[1])
    janky = float(re.search(r"Janky frames: \d+ \(([\d.]+)%\)", info)[1])
    p90 = int(re.search(r"90th percentile: (\d+)ms", info)[1])
    screenshot(f"{name}-scrolled")
    return name, frames, janky, p90


def smooth(name, frames, janky, p90):
    return (
        frames >= 30
        and janky <= SMOOTH_LIMITS[name][0]
        and p90 <= SMOOTH_LIMITS[name][1]
    )


def best_flings(name, path):
    """Up to three tries, the least janky kept: frame times follow the PC's load, which the other
    emulator's suite raises (#103). A drawing cost per row fails every try."""
    tries = []
    while len(tries) < 3 and not (tries and smooth(*tries[-1])):
        tries.append(fling_stats(name, path))
    return min(tries, key=lambda t: t[2]) + (len(tries),)


def other_emulator_busy():
    """Whether another emulator's lock is held (#103): a suite running there slows this one's frames."""
    me = adb("emu", "avd", "name").splitlines()[0].strip()
    return any(
        subprocess.run(["flock", "-n", lock, "true"], check=False).returncode != 0
        for lock in glob.glob("/tmp/agent-locks/devices/emulator-*.lock")
        if os.path.basename(lock) != f"emulator-{me}.lock"
    )


def smooth_scrolling():
    # 300 of My words, which it reads after its marker; the file goes back as it was afterwards.
    local = os.path.join(logdir, "my-words-300.txt")
    with open(local, "w", encoding="utf-8") as f:
        f.write(
            "# SebType: My words\n"
            + "".join(f"测试词{i}\tceshici{i}\n" for i in range(300))
        )
    adb("push", local, "/data/local/tmp/sebtype-words.txt")
    had = root(f"test -f {WORDS_FILE} && echo yes || true").strip() == "yes"
    if had:
        root(f"cp -p {WORDS_FILE} {WORDS_FILE}.bak")
    owner = root(f"stat -c %u:%g /data/data/{PKG}/files").strip()
    try:
        root(
            f"mkdir -p $(dirname {WORDS_FILE}) && cp /data/local/tmp/sebtype-words.txt {WORDS_FILE} && chown -R {owner} $(dirname {WORDS_FILE}) && restorecon -R $(dirname {WORDS_FILE})"
        )
        stats = [
            best_flings("zh-words-300", (LANG, (MY_WORDS, 1))),
            best_flings(
                "credits",
                (
                    HOME["about"],
                    labels(
                        "许可与致谢", "Licence and credits", "ライセンスとクレジット"
                    ),
                ),
            ),
        ]
    finally:
        root(f"mv {WORDS_FILE}.bak {WORDS_FILE}" if had else f"rm -f {WORDS_FILE}")
    summary = ", ".join(
        f"{n}: {f} frames, {j}% janky, p90 {p} ms"
        + (f" (best of {t})" if t > 1 else "")
        for n, f, j, p, t in stats
    )
    if not all(smooth(*s[:4]) for s in stats):
        # The limits hold on a quiet PC; a drawing regression shows in the next run without company.
        if other_emulator_busy():
            raise Skip(f"too slow while another emulator ran a test: {summary}")
        raise Fail(summary)
    return summary


THEME = labels("主题", "Theme")
THEME_ACTION = labels("主题切换器", "Theme Switcher")


def nothing_shows(texts, swipes):
    """Fails if any of texts shows on the screen, scrolling down swipes times."""
    for _ in range(swipes + 1):
        found = [label for label, *_ in nodes() if label in texts]
        if found:
            raise Fail(f"{found[0]!r} on the screen")
        adb("shell", "input", "swipe", "540", "1900", "540", "900", "400")
        time.sleep(1)


def no_theme_choice():
    open_settings()
    nothing_shows(THEME, 2)
    go(
        HOME["keyboard"],
        labels("操作栏按钮", "Action bar buttons", "アクションバーのボタン"),
    )
    nothing_shows(THEME_ACTION, 4)
    return "no Theme group on the home screen, no theme switcher among the actions"


# Picnic's own colours (theme/Picnic.kt): the cloth's two, the cream keys and cards, their lines, pink.
PICNIC = [
    (0xFB, 0xE9, 0xD6),
    (0xF8, 0xE2, 0xCC),
    (0xFF, 0xF7, 0xE8),
    (0xEC, 0xD0, 0xAE),
    (0xFD, 0xE0, 0xE6),
]


def picnic_share(box=None):
    """The share of the screen (or of box, x1 y1 x2 y2) in Picnic's colours, from a raw screencap."""
    raw = subprocess.run(
        ["adb", "-s", serial, "exec-out", "screencap"],
        capture_output=True,
        timeout=60,
        check=True,
    ).stdout
    w, h = int.from_bytes(raw[0:4], "little"), int.from_bytes(raw[4:8], "little")
    pixels = raw[len(raw) - w * h * 4 :]
    x1, y1, x2, y2 = box or (0, 0, w, h)
    near = total = 0
    for y in range(y1, y2, 12):
        for x in range(x1, x2, 12):
            i = (y * w + x) * 4
            r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
            total += 1
            # 12 covers the cloth's RGB_565 rounding.
            near += any(
                abs(r - pr) + abs(g - pg) + abs(b - pb) <= 12 for pr, pg, pb in PICNIC
            )
    return near / total


def dark_mode_picnic():
    adb("shell", "cmd", "uimode", "night", "yes")
    try:
        time.sleep(2)
        adb("shell", "am", "force-stop", PKG)
        open_settings()
        time.sleep(1)
        screenshot("dark-home")
        home = picnic_share()
        # Chinese, not Japanese: Mozc can crash when it starts on the emulator (#35).
        to_language("ni", "你")
        open_field()
        time.sleep(1)
        screenshot("dark-keyboard")
        keyboard = picnic_share(keyboard_frame)
    finally:
        adb("shell", "cmd", "uimode", "night", "no")
    summary = f"in dark mode {home:.0%} of the settings home and {keyboard:.0%} of the keyboard in Picnic's colours"
    # Picnic measured 92 % on the home screen and 73 % on the keyboard (guide35, 2026-11-11); a dark
    # theme is near 0.
    if home < 0.4 or keyboard < 0.4:
        raise Fail(summary)
    return summary


NOTE_ROW = labels(
    "FUTO 许可证要求；与 SebType 无关",
    "Required by FUTO's licence; not related to SebType",
)
NOTE = labels(
    "FUTO 的许可证要求 SebType 包含此页面。",
    "FUTO's licence requires SebType to include this page.",
)


def screen_contains(texts):
    return any(t in label for label, *_ in nodes() for t in texts)


def payment_note():
    go(HOME["about"])
    wait_for(
        f"the payment row's note ({NOTE_ROW[0]})", lambda: screen_contains(NOTE_ROW), 10
    )
    tap_text(labels("支持 FUTO", "Support FUTO", "FUTO を支援"))
    wait_for(f"the licence note ({NOTE[0]})", lambda: screen_contains(NOTE), 10)
    # The note only adds to FUTO's screen: its own title and payment options are still there.
    wait_for(
        "FUTO's payment title",
        lambda: screen_has(
            labels(
                "为FUTO Keyboard支付", "Pay for FUTO Keyboard", "FUTO キーボードの購入"
            )
        ),
        10,
    )
    return (
        "About's Support FUTO row and the payment screen say FUTO's licence requires it"
    )


# --- Incognito (#31): the action bar button, its badge, and what is learned and copied meanwhile ---

INCOGNITO = labels("无痕模式", "Incognito", "シークレットモード")
INCOGNITO_ON = labels(
    "无痕模式已开，点按关闭",
    "Incognito on. Tap to turn off",
    "シークレットモード オン。タップでオフ",
)
INCOGNITO_FIELD = labels(
    "此输入框为无痕模式", "Incognito in this field", "この入力欄はシークレットモード"
)
OPEN_BAR = labels("打开操作栏", "Open Action Bar", "アクションバーを開く")
CLOSE_BAR = labels("关闭操作栏", "Close Action Bar", "アクションバーを閉じる")
CLIPBOARD_FILE = f"/data/data/{PKG}/files/clipboard.json"
BAR_CONTROLS.update((*INCOGNITO_ON, *INCOGNITO_FIELD, *OPEN_BAR, *CLOSE_BAR))


def badge():
    """The incognito badge in the suggestion bar: "toggle", "field" or None."""
    ns = nodes()
    if find_all(ns, INCOGNITO_ON):
        return "toggle"
    return "field" if find_all(ns, INCOGNITO_FIELD) else None


def set_incognito(on, shot=None):
    """On through the action bar's Incognito button, off through a tap on the badge."""
    open_field()
    if (badge() == "toggle") == on:
        return
    if on:
        if not screen_has(CLOSE_BAR):  # the bar stays open from before
            tap_text(OPEN_BAR)
        if shot:
            screenshot(shot)
        tap_text(INCOGNITO)
        tap_text(CLOSE_BAR)
    else:
        tap_text(INCOGNITO_ON)
    want = "toggle" if on else None
    wait_for(f"the badge to show {want}", lambda: badge() == want, 10)


def commit_twice(word):
    """Types a made-up word and picks it from the bar as typed (the field capitalises the first one),
    or presses space if the bar doesn't offer it, twice: English suggests a word it doesn't know only
    after it is typed more than once."""
    for _ in range(2):
        type_keys(word)
        typed = [c for c in en_candidates(nodes()) if c.lower() == word]
        if typed:
            tap_candidate(typed[0])
        else:
            bottom_key(5)
            time.sleep(1.5)


def suggested_after(word, kind=None):
    """English's suggestions, in lower case, for word's first five letters in a new field."""
    open_field(kind)
    type_keys(word[:5])
    return [c.lower() for c in en_candidates(nodes())]


def incognito_toggle():
    to_language("hello", "hello")
    set_incognito(True, shot="31-action-bar.png")
    screenshot("31-badge-toggle.png")
    open_field()
    if badge() != "toggle":
        raise Fail(f"a new field after turning incognito on shows the badge {badge()}")
    return "the action bar's Incognito button turns it on; a new field still shows the badge"


def incognito_en():
    open_field()
    commit_twice("zorbleq")
    got = suggested_after("zorbleq")
    if "zorbleq" in got:
        raise Fail(f"typed zorbleq twice while incognito; zorbl -> {got[:6]}")
    return f"typed zorbleq twice while incognito; zorbl -> {got[:6]}"


def incognito_zh():
    to_language("ni", "你")
    before = candidates_for("sx")
    word = before[2]
    tap_candidate(word)
    after = candidates_for("sx")
    if word in after[:2]:
        raise Fail(
            f"sx -> {before[:4]}; picked {word} while incognito; next sx -> {after[:4]}"
        )
    return f"sx -> {before[:4]}; picked {word} while incognito; next sx -> {after[:4]}"


def incognito_ja():
    to_language("nihongo", "日本語")
    before = candidates_for("hashi")
    word = before[2]
    tap_candidate(word)
    after = candidates_for("hashi")
    if word in after[:2]:
        raise Fail(
            f"hashi -> {before[:4]}; picked {word} while incognito; next hashi -> {after[:4]}"
        )
    return f"hashi -> {before[:4]}; picked {word} while incognito; next hashi -> {after[:4]}"


def clipboard_has(text):
    return text in root(f"cat {CLIPBOARD_FILE} 2>/dev/null || true")


def clipboard_capture(text, kind=None):
    """Copies text in the field app; whether SebType's clipboard history kept it."""
    open_field(kind, clip=text)
    time.sleep(
        4
    )  # the copy comes 1.5 s after the field opens; the history saves it in the background
    return clipboard_has(text)


def incognito_clipboard():
    if adb("shell", "su 0 id -u", check=False).strip() != "0":
        raise Skip("no root shell to read the clipboard history (a phone)")
    # Clipboard history is off after a fresh install: on, then a control copy from a normal field
    # (taken before incognito is turned on) shows it is on.
    set_incognito(False)
    for _ in range(2):
        if clipboard_capture(f"sebclip-ctl-{time.time_ns()}"):
            break
        toggle(
            (HOME["privacy"],),
            labels(
                "保留剪贴板历史", "Keep clipboard history", "クリップボード履歴を残す"
            ),
        )
    else:
        raise Fail("clipboard history keeps no copy even from a normal field")
    private = f"sebclip-private-{time.time_ns()}"
    if clipboard_capture(private, kind="private"):
        raise Fail("a copy made in a private field was kept")
    # #139: the keyboard was last up in a normal field; a private field then gets focus with the
    # keyboard down, as in a private browser tab, and a copy made there is still not kept.
    open_field()
    hidden = f"sebclip-hidden-{time.time_ns()}"
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb(
        "shell",
        "am",
        "start",
        "-W",
        "-f",
        "0x10008000",
        "-n",
        FIELD,
        "--es",
        "kind",
        "private",
        "--es",
        "clip",
        hidden,
        "--ez",
        "hidden",
        "true",
    )
    time.sleep(4)
    if keys(nodes()):
        raise Fail("the keyboard showed in the field meant to keep it down")
    if clipboard_has(hidden):
        raise Fail(
            "a copy made in a private field the keyboard never showed in was kept"
        )
    set_incognito(True)
    copied = f"sebclip-incog-{time.time_ns()}"
    if clipboard_capture(copied):
        raise Fail("a copy made while incognito was kept")
    return "copies from a private field (keyboard up or never shown there) and while incognito not kept; a normal one is"


def incognito_after_restart():
    adb("shell", "am", "force-stop", PKG)
    open_field()
    wait_for("the badge after a restart", lambda: badge() == "toggle", 15)
    return "incognito still on after the keyboard restarted"


def incognito_privacy_switch():
    go(HOME["privacy"])
    if not screen_has(INCOGNITO):
        raise Fail("no Incognito switch in Privacy")
    screenshot("31-privacy.png")
    return "Privacy shows the Incognito switch"


def incognito_auto_fields():
    shown = {}
    for kind in ("password", "private"):
        open_field(kind)
        shown[kind] = badge()
        screenshot(f"31-badge-{kind}.png")
    open_field()
    shown["normal"] = badge()
    if shown != {"password": "field", "private": "field", "normal": None}:
        raise Fail(f"badge per field: {shown}")
    return f"badge per field: {shown}"


def incognito_private_en():
    to_language("hello", "hello")
    open_field("private")
    commit_twice("vemquat")
    got = suggested_after("vemquat")
    if "vemquat" in got:
        raise Fail(f"typed vemquat twice in a private field; vemqu -> {got[:6]}")
    return f"typed vemquat twice in a private field; vemqu -> {got[:6]}"


def incognito_private_ja():
    to_language("nihongo", "日本語")
    before = candidates_for("kami")
    word = before[2]
    private = candidates_for("kami", kind="private")
    if word not in private:
        raise Fail(f"kami -> {before[:4]}, but in a private field -> {private[:4]}")
    tap_candidate(word)
    after = candidates_for("kami")
    if word in after[:2]:
        raise Fail(
            f"kami -> {before[:4]}; picked {word} in a private field; next kami -> {after[:4]}"
        )
    return f"kami -> {before[:4]}; picked {word} in a private field; next kami -> {after[:4]}"


def learns_again_en():
    """After incognito: English learns again, and still offers what it learned once incognito is back
    on (Decisions #2, #158: incognito stops learning, not the use of what was learned)."""
    to_language("hello", "hello")
    open_field()
    commit_twice("zorbleq")
    got = suggested_after("zorbleq")
    if "zorbleq" not in got:
        raise Fail(f"typed zorbleq twice after incognito; zorbl -> {got[:6]}")
    set_incognito(True)
    kept = suggested_after("zorbleq")
    set_incognito(False)
    detail = f"zorbl -> {got[:6]} after incognito; {kept[:6]} while incognito again"
    if "zorbleq" not in kept:
        raise Fail(detail)
    return detail


def learns_again(probe, probe_word, code):
    """After incognito the language learns again: a lower candidate picked goes first. Once incognito
    is back on, it stays first (#158)."""

    def run():
        to_language(probe, probe_word)
        word = candidates_for(code)[1]
        tap_candidate(word)
        after = candidates_for(code)
        detail = f"picked {word} for {code} after incognito; next {code} -> {after[:4]}"
        if after[0] != word:
            raise Fail(detail)
        set_incognito(True)
        kept = candidates_for(code)
        set_incognito(False)
        detail += f"; while incognito again -> {kept[:4]}"
        if kept[0] != word:
            raise Fail(detail)
        return detail

    return run


# --- Clipboard history in a settings backup (#34) ---

CLIP_BOX = labels(
    "包含剪贴板历史", "Include clipboard history", "クリップボード履歴を含める"
)
EXPORT = labels("导出设置", "Export settings", "設定をエクスポート")
IMPORT = labels("导入设置", "Import settings", "設定をインポート")
SAVE = labels("保存", "SAVE", "Save")
IMPORT_BUTTON = labels("导入", "Import", "インポート")
KEEP_HISTORY = labels(
    "保留剪贴板历史", "Keep clipboard history", "クリップボード履歴を残す"
)
FILES = f"/data/data/{PKG}/files"
# Made-up entries only, never anyone's real clipboard.
CLIP_TEXT = "SebType test clip 34"
CLIP_FILE = "sebtype-test-34.txt"
# Pinned, so the app's pruning keeps both; the second points to a file in clipboardfiles/.
CLIP_JSON = (
    '[{"timestamp":1,"pinned":true,"text":"' + CLIP_TEXT + '","uri":null,'
    '"mimeTypes":["text/plain"]},'
    '{"timestamp":2,"pinned":true,"text":null,"uri":null,"mimeTypes":["text/plain"],'
    '"backingFile":"' + CLIP_FILE + '","sizeMb":0.0}]'
)


def is_checked(texts):
    """The state of the checkbox or switch row showing one of texts."""
    adb("shell", "uiautomator", "dump", "/sdcard/sebtype-ui.xml")
    xml = adb("shell", "cat", "/sdcard/sebtype-ui.xml")
    for n in ET.fromstring(xml[xml.index("<") :]).iter("node"):
        label = n.get("text") or n.get("content-desc") or ""
        if n.get("checkable") == "true" and any(label.startswith(t) for t in texts):
            return n.get("checked") == "true"
    raise Fail(f"no {texts[1]} checkbox or switch")


def keep_clipboard_history(on):
    go(HOME["privacy"])
    if is_checked(KEEP_HISTORY) != on:
        tap_text(KEEP_HISTORY)


def seed_clipboard():
    """Made-up clipboard history in the app's files, written while the app is stopped. With
    history off, the app deletes it when it starts."""
    keep_clipboard_history(True)
    adb("shell", "am", "force-stop", PKG)
    tmp = "/data/local/tmp/sebtype-clipboard.json"
    adb("shell", f"echo '{CLIP_JSON}' > {tmp}")
    uid = root(f"stat -c %u {FILES}").strip()
    root(
        f"cp {tmp} {FILES}/clipboard.json && mkdir -p {FILES}/clipboardfiles && "
        f"echo made-up > {FILES}/clipboardfiles/{CLIP_FILE} && "
        f"chown -R {uid}:{uid} {FILES}/clipboard.json {FILES}/clipboardfiles && "
        f"restorecon -R {FILES}/clipboard.json {FILES}/clipboardfiles"
    )


def clear_clipboard():
    adb("shell", "am", "force-stop", PKG)
    root(f"rm -rf {FILES}/clipboard.json* {FILES}/clipboardfiles")


def clipboard_on_device():
    return CLIP_TEXT in root(f"cat {FILES}/clipboard.json 2>/dev/null; true") and (
        CLIP_FILE in root(f"ls {FILES}/clipboardfiles 2>/dev/null; true")
    )


def export_backup(include_clipboard, name):
    """Exports from the backup screen into Downloads; returns the backup's entry names."""
    go(HOME["backup"])
    if is_checked(CLIP_BOX):
        raise Fail("the clipboard checkbox starts ticked")
    if include_clipboard:
        tap_text(CLIP_BOX)
        if not is_checked(CLIP_BOX):
            raise Fail("tapping the clipboard checkbox doesn't tick it")
    adb("shell", "rm -f /sdcard/Download/FUTOKeyboardSettings_*.backup")
    tap_text(EXPORT)
    wait_for("the save dialog", lambda: screen_has(SAVE), 20)
    if not screen_has(labels("下载", "Downloads", "Download")):
        tap_text(labels("显示根目录", "Show roots"))
        tap_text(labels("下载", "Downloads"))
    tap_text(SAVE)
    path = wait_for(
        "the exported backup",
        lambda: adb(
            "shell", "ls /sdcard/Download/FUTOKeyboardSettings_*.backup", check=False
        ).strip(),
        60,
    )
    wait_for("the export to finish", lambda: screen_has(EXPORT), 60)
    adb("shell", f"mv {path} /sdcard/Download/{name}")
    local = os.path.join(logdir, name)
    adb("pull", f"/sdcard/Download/{name}", local)
    with zipfile.ZipFile(local) as z:
        return z.namelist()


def import_backup(name):
    go(HOME["backup"])
    tap_text(IMPORT)
    wait_for(f"{name} in the file picker", lambda: screen_has((name,)), 20)
    tap_text((name,))
    tap_text(IMPORT_BUTTON)
    wait_for("the import to finish", lambda: not screen_has(IMPORT_BUTTON), 120)


def has_clipboard(entries):
    return "clipboard.json" in entries or any(
        e.startswith("clipboard/") for e in entries
    )


def backup_clipboard():
    seed_clipboard()
    off = export_backup(False, "sebtype-34-off.backup")
    if has_clipboard(off):
        raise Fail(f"clipboard history in a backup with the box off: {off}")
    on = export_backup(True, "sebtype-34-on.backup")
    if "clipboard.json" not in on or f"clipboard/{CLIP_FILE}" not in on:
        raise Fail(f"no clipboard history in a backup with the box ticked: {on}")
    clear_clipboard()
    import_backup("sebtype-34-on.backup")
    wait_for("the imported clipboard history", clipboard_on_device, 30)
    # A backup without clipboard history leaves the one on the phone alone.
    import_backup("sebtype-34-off.backup")
    if not clipboard_on_device():
        raise Fail("importing a backup without clipboard history removed the phone's")
    adb("shell", "rm -f /sdcard/Download/sebtype-34-*.backup")
    clear_clipboard()
    keep_clipboard_history(False)
    return "box off by default leaves it out; ticked includes it and import restores it"


def backup_screenshots():
    """The backup screen in English and Japanese, whatever the system language."""
    try:
        for lang in ("en-US", "ja-JP"):
            adb("shell", "cmd", "locale", "set-app-locales", PKG, "--locales", lang)
            adb("shell", "am", "force-stop", PKG)
            go(HOME["backup"])
            wait_for(f"the {lang} checkbox", lambda: screen_has(CLIP_BOX), 10)
            screenshot(f"backup-{lang}")
    finally:
        adb(
            "shell",
            "cmd",
            "locale",
            "set-app-locales",
            PKG,
            "--locales",
            "",
            check=False,
        )
    return "settings-backup-en-US.png, settings-backup-ja-JP.png"


adb("logcat", "-c")
check("settings-screens", every_screen)
check("settings-globe-order", globe_order)
check("settings-zh-punctuation", full_width_punctuation)
check("settings-zh-emoji", emoji_candidates)
check("settings-zh-my-words", my_words)
check("settings-zh-forget", forget_chinese)
check("settings-ja-forget", forget_japanese)
check("settings-no-theme-choice", no_theme_choice)
check("settings-dark-mode-picnic", dark_mode_picnic)
check("settings-payment-note", payment_note)
check("settings-smooth-scrolling", smooth_scrolling)


# --- The settings in 日本語 (#120) ---

HERE = os.path.dirname(os.path.abspath(__file__))


# --- Sync with the user's own server (#12) ---
# A local sync-server on this PC (127.0.0.1, which the emulator reaches as 10.0.2.2) over HTTPS with a
# made-up certificate authority the emulator trusts until the end of the run, a made-up login and
# made-up words. Nothing of the maintainer's own server.
SYNC_USER, SYNC_PASSWORD = "sebtype-test", "made-up-pass-4821"
OTHER_DEVICE = "5e5e5e5e-0000-4000-8000-000000000012"  # a made-up second device
OTHER_CODE, OTHER_WORD = "lu lu", "鹿芦"
SYNC = {}  # the server process, its port and data dir, the CA's file name on the emulator, airplane mode before
NO_BACKUP = f"/data/data/{PKG}/no_backup"
RIME_USER = f"/data/data/{PKG}/files/rime/user"
SYNC_LOGIN = labels("服务器和登录", "Server and login", "サーバーとログイン")
SYNC_DELETE = labels(
    "删除服务器上学到的词",
    "Delete learned words on the server",
    "サーバー上の学習した単語を削除",
)
SYNC_OFFLINE = ("无法连接服务器", "Can't reach the server", "サーバーに接続できません")
SYNC_SYNCED = ("上次同步", "Last synced", "前回の同期")
SYNC_OFF = ("通过你自己的服务器", "with your own server", "自分のサーバーと")
CA_SCRIPT = r"""set -u
d=/data/local/tmp/sebtype-cacerts apex=/apex/com.android.conscrypt/cacerts
zygotes=$(pidof zygote64 zygote)
if [ "$1" = add ]; then
  rm -rf $d; mkdir -p $d; cp $apex/* $d/; cp /data/local/tmp/$2 $d/
  label=$(ls -Z $apex/$(ls $apex | head -1) | cut -d" " -f1)
  for z in $zygotes; do
    nsenter --mount=/proc/$z/ns/mnt -- sh -c "mount -t tmpfs tmpfs $apex && cp $d/* $apex/ && chmod 755 $apex && chmod 644 $apex/* && chcon $label $apex $apex/*" || exit 1
  done
else
  for z in $zygotes; do nsenter --mount=/proc/$z/ns/mnt -- umount $apex; done
  rm -rf $d /data/local/tmp/$2 /data/local/tmp/sebtype-ca.sh
fi
"""


def sync_server_dir(*parts):
    return os.path.join(SYNC["data"], "files", SYNC_USER, *parts)


def openssl(*args, cwd):
    subprocess.run(
        ["openssl", *args], cwd=cwd, check=True, capture_output=True, timeout=60
    )


def start_sync_server():
    """The server with TLS from a made-up CA, whose certificate the emulator's apps trust meanwhile."""
    d = os.path.join(logdir, "sync-server")
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    openssl(
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        "ca.key",
        "-out",
        "ca.pem",
        "-days",
        "2",
        "-subj",
        "/CN=SebType test CA (made up)",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign",
        cwd=d,
    )
    openssl(
        "req",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-keyout",
        "server.key",
        "-out",
        "server.csr",
        "-subj",
        "/CN=10.0.2.2",
        cwd=d,
    )
    with open(os.path.join(d, "ext.cnf"), "w") as f:
        f.write("subjectAltName=IP:10.0.2.2\nextendedKeyUsage=serverAuth\n")
    openssl(
        "x509",
        "-req",
        "-in",
        "server.csr",
        "-CA",
        "ca.pem",
        "-CAkey",
        "ca.key",
        "-CAcreateserial",
        "-out",
        "server.pem",
        "-days",
        "2",
        "-extfile",
        "ext.cnf",
        cwd=d,
    )
    SYNC["data"] = os.path.join(d, "data")
    server = os.path.join(HERE, "..", "sync-server", "sebtype_sync.py")
    subprocess.run(
        [
            sys.executable,
            "-I",
            server,
            "adduser",
            "--data",
            SYNC["data"],
            SYNC_USER,
            "--password-stdin",
        ],
        input=SYNC_PASSWORD + "\n",
        text=True,
        check=True,
        timeout=60,
    )
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        SYNC["port"] = sock.getsockname()[1]
    SYNC["log"] = open(os.path.join(d, "server.log"), "w")  # noqa: SIM115 (open while the server runs)
    SYNC["server"] = subprocess.Popen(
        [
            sys.executable,
            "-I",
            server,
            "serve",
            "--data",
            SYNC["data"],
            "--port",
            str(SYNC["port"]),
            "--tls-cert",
            os.path.join(d, "server.pem"),
            "--tls-key",
            os.path.join(d, "server.key"),
        ],
        stdout=SYNC["log"],
        stderr=subprocess.STDOUT,
    )
    wait_for(
        "the sync server",
        lambda: socket.socket().connect_ex(("127.0.0.1", SYNC["port"])) == 0,
        30,
    )

    name = (
        subprocess.run(
            [
                "openssl",
                "x509",
                "-subject_hash_old",
                "-noout",
                "-in",
                os.path.join(d, "ca.pem"),
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        + ".0"
    )
    with open(os.path.join(d, "ca.sh"), "w") as f:
        f.write(CA_SCRIPT)
    adb("push", os.path.join(d, "ca.pem"), f"/data/local/tmp/{name}")
    adb("push", os.path.join(d, "ca.sh"), "/data/local/tmp/sebtype-ca.sh")
    SYNC["ca"] = name
    root(f"sh /data/local/tmp/sebtype-ca.sh add {name}")
    # SebType's process forks from zygote again, now with the CA.
    adb("shell", "am", "force-stop", PKG)


def stop_sync_server():
    if "airplane" in SYNC:
        airplane(SYNC.pop("airplane") == "1")
    if "ca" in SYNC:
        root(f"sh /data/local/tmp/sebtype-ca.sh remove {SYNC.pop('ca')}")
        adb("shell", "am", "force-stop", PKG)
    if "server" in SYNC:
        SYNC.pop("server").terminate()
        SYNC.pop("log").close()


def airplane(on):
    adb("shell", "cmd", "connectivity", "airplane-mode", "enable" if on else "disable")
    # Some images keep Wi-Fi on in airplane mode; the emulator's Wi-Fi and data are on by default.
    adb("shell", "svc", "wifi", "disable" if on else "enable")
    adb("shell", "svc", "data", "disable" if on else "enable")
    reachable = lambda: adb(
        "shell", "ping", "-c", "1", "-W", "2", "10.0.2.2", check=False, timeout=30
    )
    wait_for(
        "the network " + ("off" if on else "back"),
        lambda: (" 0% packet loss" in reachable()) != on,
        60,
        interval=3,
    )


def sync_by_hiding():
    """Hides the keyboard over a minute after it was last up: a hide syncs at most once a minute."""
    adb("shell", "input", "keyevent", "KEYCODE_HOME")
    time.sleep(62)
    open_field()
    adb("shell", "input", "keyevent", "KEYCODE_BACK")


def server_snapshot(device):
    path = sync_server_dir(device, "rime_ice.userdb.txt")
    if not os.path.isfile(path):
        return ""
    with open(path, encoding="utf-8") as f:
        return f.read()


def sync_setup():
    to_language("ni", "你")
    start_sync_server()
    go(HOME["backup"], SYNC_LOGIN)
    set_text(0, f"10.0.2.2:{SYNC['port']}")
    set_text(1, SYNC_USER)
    set_text(2, SYNC_PASSWORD)
    screenshot("12-sync-login")
    tap_text(labels("保存", "Save"))
    # A first login turns sync on and syncs: this phone's learned words arrive in its own folder.
    devices = wait_for(
        "this phone's folder on the server",
        lambda: os.path.isdir(sync_server_dir()) and os.listdir(sync_server_dir()),
        90,
    )
    SYNC["device"] = devices[0]
    wait_for("its snapshot", lambda: server_snapshot(SYNC["device"]), 30)
    wait_for("the status 'Last synced'", lambda: screen_contains(SYNC_SYNCED), 20)
    screenshot("12-sync-section")
    return f"login saved, sync on; the phone's folder {SYNC['device'][:8]}… arrived; status Last synced"


def sync_offline_learns():
    SYNC["airplane"] = adb(
        "shell", "settings", "get", "global", "airplane_mode_on"
    ).strip()
    airplane(True)
    words = candidates_for("maogoujiya")
    SYNC["word"] = words[0]
    tap_candidate(SYNC["word"])
    sync_by_hiding()
    go(HOME["backup"])
    wait_for(
        "the status 'Can't reach the server'", lambda: screen_contains(SYNC_OFFLINE), 30
    )
    screenshot("12-sync-offline")
    if SYNC["word"] in server_snapshot(SYNC["device"]):
        raise Fail(f"{SYNC['word']} reached the server in airplane mode")
    return f"offline: picked {SYNC['word']} for maogoujiya; status Can't reach the server; not on the server"


def sync_online_uploads():
    airplane(False)
    sync_by_hiding()
    snapshot = wait_for(
        f"{SYNC['word']} on the server",
        lambda: (
            (s := server_snapshot(SYNC["device"])) and f"\t{SYNC['word']}\t" in s and s
        ),
        90,
    )
    folders = os.listdir(sync_server_dir())
    if folders != [SYNC["device"]]:
        raise Fail(f"folders on the server: {folders}")
    line = next(l for l in snapshot.splitlines() if f"\t{SYNC['word']}\t" in l)
    return f"back online, a keyboard hide uploaded it: {line!r}; only the phone's own folder"


def sync_other_device():
    before = candidates_for(OTHER_CODE.replace(" ", ""), expand=True)
    if OTHER_WORD in before:
        raise Fail(f"{OTHER_WORD} offered before it was synced: {before[:8]}")
    # The other device's snapshot, in the phone's format with its own id and one made-up word.
    snapshot = server_snapshot(SYNC["device"])
    line = next(l for l in snapshot.splitlines() if f"\t{SYNC['word']}\t" in l)
    key = OTHER_CODE + (" " if line.split("\t")[0].endswith(" ") else "")
    tick = re.search(r"^#@/tick\t(\d+)", snapshot, re.MULTILINE)[1]
    header = [
        re.sub(r"^#@/user_id\t.*", f"#@/user_id\t{OTHER_DEVICE}", l)
        for l in snapshot.splitlines()
        if l.startswith("#")
    ]
    os.makedirs(sync_server_dir(OTHER_DEVICE))
    with open(
        sync_server_dir(OTHER_DEVICE, "rime_ice.userdb.txt"), "w", encoding="utf-8"
    ) as f:
        f.write("\n".join(header + [f"{key}\t{OTHER_WORD}\tc=50 d=50 t={tick}"]) + "\n")
    sync_by_hiding()
    wait_for(
        "the other device's snapshot on the phone",
        lambda: (
            "rime_ice.userdb.txt"
            in root(f"ls {RIME_USER}/sync/{OTHER_DEVICE} 2>/dev/null; true")
        ),
        60,
    )
    time.sleep(10)  # Rime merges it right after the download
    got = candidates_for(OTHER_CODE.replace(" ", ""), expand=True)
    if OTHER_WORD not in got:
        raise Fail(f"after the sync, lulu -> {got[:8]}")
    return f"a made-up word in another device's folder: lulu -> {got[: got.index(OTHER_WORD) + 1]} after a sync"


def sync_delete_on_server():
    go(HOME["backup"], SYNC_DELETE)
    screenshot("12-sync-delete")
    found = find_all(nodes(), labels("删除", "Delete", "削除"))
    y, x = found[-1]  # the dialog's button, below its title
    tap(x, y)
    wait_for("the server emptied", lambda: not os.path.isdir(sync_server_dir()), 30)
    go(HOME["backup"])
    wait_for("sync shown as off", lambda: screen_contains(SYNC_OFF), 20)
    return "the button deleted every device's words on the server and turned sync off"


def sync_credentials_private():
    found = []
    if SYNC_PASSWORD in adb("logcat", "-d", timeout=120):
        found.append("logcat")
    if "account" not in root(f"ls {NO_BACKUP}/sync 2>/dev/null; true").split():
        raise Fail(f"no account file in {NO_BACKUP}/sync")
    # grep prints only the names of files with the password or username in plain text.
    plain = root(
        f"grep -rl -e {SYNC_PASSWORD} -e {SYNC_USER} /data/data/{PKG} 2>/dev/null | head -5; true"
    ).split()
    if plain:
        found.append(f"files of the app: {plain}")
    if found:
        raise Fail(f"the login in plain text in {found}")
    return "the login is in no log and no file of the app in plain text (no_backup/sync/account is encrypted)"


def english_strings():
    """SebType's English strings as patterns (%d is any number), and FUTO's one SebType translates;
    not those that read the same in 日本語 (the name SebType)."""

    def strings(path):
        return {e.get("name"): e for e in ET.parse(os.path.join(HERE, path)).getroot()}

    texts = {"Fuzzy Pinyin"}
    for d, f in (
        ("res", "strings-sebtype.xml"),
        ("res-stable", "strings-sebtype-overrides.xml"),
    ):
        ja = strings(f"{d}/values-ja/{f}")
        for name, e in strings(f"{d}/values/{f}").items():
            if e.get("translatable") != "false" and (
                name not in ja or ja[name].text != e.text
            ):
                texts.add(e.text)
    return [
        re.compile(
            re.escape(t.replace("\\'", "'").replace("\\n", "\n"))
            .replace("%d", r"\d+")
            .replace("%%", "%")
        )
        for t in texts
    ]


def english_on_screen(patterns):
    """The visible labels, or parts of one joined with " · ", ", " or a line break, that are SebType English."""
    found = set()
    for label, *_ in nodes():
        for part in {label, *re.split(r"\n| · |, ", label)}:
            if any(p.fullmatch(part) for p in patterns):
                found.add(part)
    return found


def system_locale(tag):
    """Sets the system's language list to tag alone with test-emulator.sh's set-locale helper (the way
    Settings does it, without a restart, which can crash the emulator; docs/testing.md)."""
    dex = "/data/local/tmp/sebtype-set-locale.dex"
    adb("push", os.path.join(logdir, "set-locale.dex"), dex)
    try:
        adb(
            "shell",
            "app_process",
            "-cp",
            dex,
            "/",
            "dev.sebb.sebtype.setlocale.SetLocale",
            tag,
        )
    finally:
        adb("shell", "rm", "-f", dex, check=False)
    config = tag.replace("-", "-r")  # am get-config writes ja-JP as ja-rJP
    wait_for(
        f"the system in {tag}",
        lambda: re.search(rf"[ -]{config}-", adb("shell", "am", "get-config")),
        30,
    )
    time.sleep(3)  # open apps redraw in the new language


def japanese_ui():
    for f in glob.glob(os.path.join(logdir, "settings-ja-*.png")):
        os.remove(f)  # a last run's extra pages would pass for this run's
    system_locale("ja-JP")
    patterns = english_strings()
    english = {}
    failed = []
    for name, path, marker in SCREENS:
        try:
            go(*path)
            wait_for(f"{name} ({marker[-1]})", lambda m=marker: screen_has(m), 10)
        except Fail as e:
            failed.append(f"{name}: {e}")
        screenshot(f"ja-{name}")
        seen = english_on_screen(patterns)
        # Down the screen too, a page at a time; resizing's page is the keyboard's handles.
        for page in range(2, 6 if name != "resize" else 2):
            before = {label for label, *_ in nodes()}
            adb("shell", "input", "swipe", "540", "1900", "540", "900", "400")
            time.sleep(1)
            if {label for label, *_ in nodes()} == before:
                break
            screenshot(f"ja-{name}-{page}")
            seen |= english_on_screen(patterns)
        if seen:
            english[name] = sorted(seen)
    if english:
        failed.append(f"English on {english}")
    if failed:
        raise Fail("; ".join(failed))
    return f"{len(SCREENS)} screens in 日本語, no English SebType string (settings-ja-*.png)"


check("settings-japanese", japanese_ui)
# test-emulator.sh runs everything else in en-US.
check(
    "settings-locale-back",
    lambda: system_locale("en-US") or "the system is back in en-US",
)

check("incognito-auto-fields", incognito_auto_fields)
check("incognito-private-en", incognito_private_en)
check("incognito-private-ja", incognito_private_ja)
check("incognito-toggle-on", incognito_toggle)
check("incognito-en", incognito_en)
check("incognito-after-restart", incognito_after_restart)
check("incognito-privacy-switch", incognito_privacy_switch)
check("incognito-zh", incognito_zh)
check("incognito-ja", incognito_ja)
check("incognito-clipboard", incognito_clipboard)
check(
    "incognito-badge-tap-off",
    lambda: set_incognito(False) or "a tap on the badge turns incognito off",
)
check("incognito-off-learns-en", learns_again_en)
check("incognito-off-learns-zh", learns_again("ni", "你", "sx"))
check("incognito-off-learns-ja", learns_again("nihongo", "日本語", "hashi"))
try:
    check("sync-setup", sync_setup)
    check("sync-offline-learns", sync_offline_learns)
    check("sync-online-uploads", sync_online_uploads)
    check("sync-other-device", sync_other_device)
    check("sync-credentials-private", sync_credentials_private)
    check("sync-delete-on-server", sync_delete_on_server)
finally:
    stop_sync_server()
# Last, in en-US: importing a backup reinstalls the Chinese data in the background.
check("settings-backup-clipboard", backup_clipboard)
check("settings-backup-screenshots", backup_screenshots)
adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
