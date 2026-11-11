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
in their pixel-framed cards on the cloth (#87). Labels match the emulator's Chinese UI or English. One line per check
appended to RESULTS; each check finds its own way from the home screen, so one failing doesn't
stop the next.
"""

import functools
import os
import re
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

serial, results_path, logdir = sys.argv[1:4]
PKG = "dev.sebb.sebtype"
IME = f"{PKG}/org.futo.inputmethod.latin.LatinIME"
SETTINGS = f"{PKG}/org.futo.inputmethod.latin.uix.settings.SettingsActivity"
FIELD = "dev.sebb.sebtype.perffield/.PerfField"
PREPARING = ("正在准备中文", "Preparing Chinese")
NOT_CANDIDATES = (*PREPARING, "中文输入启动失败", "Chinese input failed")
log_path = os.path.join(logdir, "test-settings.log")


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
    k = wait_for("the keyboard", lambda: keys(nodes()), 30)
    for ch in text:
        tap(k[ch][0], k[ch][1])
    time.sleep(1.5)


def open_field():
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
    adb("shell", "ime", "set", IME)
    adb("shell", "am", "start", "-W", "-f", "0x10008000", "-n", FIELD)
    wait_for("the keyboard", lambda: keys(nodes()), 30)


def candidates_for(text, expand=False):
    open_field()
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
    """Cycles the globe until typing probe offers word (中: ni -> 你, 日: nihongo -> 日本語)."""
    for _ in range(8):
        try:
            open_field()
            type_keys(probe)
            # Chinese sets itself up the first time it comes up, showing its notice meanwhile.
            end = time.time() + 300
            while True:
                ns = nodes()
                if word in candidates(ns):
                    return
                preparing = any(n[0].startswith(PREPARING) for n in ns)
                if not preparing or time.time() > end:
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
    "languages": labels("语言", "Languages"),
    "keyboard": labels("键盘", "Keyboard"),
    "privacy": labels("隐私", "Privacy"),
    "backup": labels("同步与备份", "Sync & backup"),
    "about": labels("关于", "About"),
}
MY_WORDS = labels("我的词语", "My words")
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
    try:
        detail = fn()
        result("PASS", name, detail or "")
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
    ("home", (), labels("同步与备份", "Sync & backup")),
    ("languages", (LANG,), labels("地球键顺序", "Globe order")),
    (
        "en-words",
        (LANG, (MY_WORDS, 0)),
        labels("添加", '"添加"', "Add", "Words", "词语"),
    ),
    (
        "zh-fuzzy",
        (LANG, labels("Fuzzy Pinyin", "模糊拼音")),
        labels("zh=z", "zh = z", "z=zh", "z = zh", "zh, ch, sh"),
    ),
    ("zh-words", (LANG, (MY_WORDS, 1)), labels("还没有词语", "No words yet")),
    (
        "ja-words",
        (LANG, (MY_WORDS, 2)),
        labels("添加", '"添加"', "Add", "Words", "词语"),
    ),
    ("keyboard", (HOME["keyboard"],), labels("尺寸和位置", "Size and position")),
    (
        "resize",
        (HOME["keyboard"], labels("尺寸和位置", "Size and position")),
        labels("调整键盘大小", "Resize Keyboard"),
    ),
    (
        "action-bar",
        (HOME["keyboard"], labels("操作栏按钮", "Action bar buttons")),
        labels("编辑快捷方式", "Edit Actions"),
    ),
    ("privacy", (HOME["privacy"],), labels("从我的输入中学习", "Learn from my typing")),
    (
        "forget",
        (HOME["privacy"], labels("忘记学到的词", "Forget learned words")),
        labels("忘记", "Forget"),
    ),
    ("backup", (HOME["backup"],), labels("导出设置", "Export settings")),
    ("about", (HOME["about"],), labels("版本", "Version")),
    (
        "credits",
        (HOME["about"], labels("许可与致谢", "Licence and credits")),
        labels("Credits", "致谢"),
    ),
    (
        "payment",
        (HOME["about"], labels("支持 FUTO", "Support FUTO")),
        labels("为FUTO Keyboard支付", "Pay for FUTO Keyboard"),
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
    go(HOME["privacy"], labels("忘记学到的词", "Forget learned words"))
    tap_text(language)
    found = find_all(nodes(), labels("忘记", "Forget"))
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
                "credits", (HOME["about"], labels("许可与致谢", "Licence and credits"))
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
    go(HOME["keyboard"], labels("操作栏按钮", "Action bar buttons"))
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
    tap_text(labels("支持 FUTO", "Support FUTO"))
    wait_for(f"the licence note ({NOTE[0]})", lambda: screen_contains(NOTE), 10)
    # The note only adds to FUTO's screen: its own title and payment options are still there.
    wait_for(
        "FUTO's payment title",
        lambda: screen_has(labels("为FUTO Keyboard支付", "Pay for FUTO Keyboard")),
        10,
    )
    return (
        "About's Support FUTO row and the payment screen say FUTO's licence requires it"
    )


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
adb("shell", "input", "keyevent", "KEYCODE_BACK", check=False)
