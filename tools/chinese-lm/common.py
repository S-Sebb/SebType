"""What the corpus, the training data and the harness's sets share: the sources' documents and which split
each is in, their text cleaned the same way, clauses, the pinyin typed for a text, and the typos made in it.

Pinyin is pypinyin's (full pinyin as rime-ice spells it: ü as v, so 绿 is lv), one syllable per Han character,
read for a whole clause, so a span cut out of it keeps the reading its words give it (重 of 重庆 is chong). Where
pypinyin reads a word of 白霜's dictionary (Rime's) otherwise than the dictionary does (多长时间 as duozhang…),
the dictionary's reading is taken (readings(), #557). A typo follows the phone error mix of #46
(data/rime/bench/make-typos.py: touch slips on SebType's key grid, missing, extra and swapped letters) with the
pinyin confusions added: zh/z, ch/c, sh/s and ng/n, either way, and, more rarely, the app's other fuzzy pinyin
pairs l/n, f/h, r/l and k/g.
"""

import bz2
import glob
import gzip
import hashlib
import json
import re
import xml.etree.ElementTree as ET
from pathlib import Path

import opencc

HAN = re.compile(r"[㐀-䶿一-鿿]")
HAN_RUN = re.compile(r"[㐀-䶿一-鿿]+")
# Spaces between characters: any between two Han characters, and between a Han character and another.
CJK_SPACE = re.compile(r"(?<=[^\x00-\x7f]) +| +(?=[^\x00-\x7f])")
BAD = re.compile(r"https?:|www\.|[`{}<>|@#\\^~_\[\]=*]|\.\w{2,4}/")
_t2s = opencc.OpenCC("t2s")


def clean(s):
    """The text in simplified characters with Chinese spacing, or None when it isn't a line of Chinese."""
    s = CJK_SPACE.sub("", " ".join(s.split()))
    if not s or BAD.search(s) or not s.isprintable():
        return None
    if len(HAN.findall(s)) < 0.5 * len(s):
        return None
    return _t2s.convert(s)


# --- the sources' documents and their split -------------------------------------------------------------
#
# A document is what a split keeps together: an article, a dialogue, a meeting, a message tree, a sentence.
# split() puts each in train, dev (the dev loss and the harness's dev sets) or test (the harness's test sets,
# which the corpus never reads), by a hash of its source and key, so corpus.py and make_sets.py agree.

# Per 10,000 documents: (test, dev).
HELD = {
    "wikipedia": (0, 20),
    "oasst2": (300, 300),
    "hundredcv": (150, 150),
    "kdconv": (200, 200),
    "tatoeba": (200, 200),
}
CHAT = ["meetings", "hundredcv", "tatoeba", "kdconv", "oasst2"]


def split(source, key):
    test, dev = HELD[source]
    h = int(hashlib.md5(f"{source}:{key}".encode()).hexdigest()[:8], 16) % 10000
    return "test" if h < test else "dev" if h < test + dev else "train"


def wikinews(path):
    """Each article of a Wikinews dump as (page id, title, paragraphs), the wikitext made plain."""
    import mwparserfromhell

    ns = "{http://www.mediawiki.org/xml/export-0.11/}"
    with bz2.open(path, "rb") as f:
        for _, el in ET.iterparse(f):
            if el.tag != ns + "page":
                continue
            text = el.findtext(f"{ns}revision/{ns}text") or ""
            if (
                el.findtext(ns + "ns") == "0"
                and el.find(ns + "redirect") is None
                and "{{Publish" in text
            ):
                title = el.findtext(ns + "title")
                yield (
                    int(el.findtext(ns + "id")),
                    title,
                    paragraphs(mwparserfromhell, text),
                )
            el.clear()


def paragraphs(mw, text):
    # The article's body ends at its first section (sources, links).
    body = re.split(r"\n==", text, maxsplit=1)[0]
    out = []
    for p in body.split("\n"):
        p = p.strip()
        if (
            not p
            or p[0] in "*#:;{|!="
            or p.startswith("[[Category")
            or p.startswith("[[File")
        ):
            continue
        plain = mw.parse(p).strip_code().strip()
        if plain:
            out.append(plain)
    return out


def news_split(src):
    """Wikinews's published articles, newest first, split: the 200 newest test, the 400 before them dev."""
    arts = sorted(wikinews(Path(src) / "zhwikinews-20261101.xml.bz2"), reverse=True)
    return {"test": arts[:200], "dev": arts[200:600], "train": arts[600:]}


# AISHELL-4's transcripts mark silences, noise and overlaps (<sil>, <%>, &): taken out, they leave the words.
MARKS = re.compile(r"<[^>]*>|&")


def meetings(src):
    """(split, session, turns) for each meeting: AliMeeting's and AISHELL-4's train sessions train, their
    evaluation and test sessions, in turn, dev and test. A turn is one speaker's interval, in time order."""
    held = []
    for name in sorted(Path(src, "meetings").iterdir()):
        for f in sorted(glob.glob(f"{name}/**/*.TextGrid", recursive=True)):
            # AliMeeting's headset files are one speaker's each (R0003_M0046_F_SPK0093): a session is its room
            # and meeting; a far-field file and AISHELL-4's hold every speaker.
            stem = Path(f).stem
            session = (
                "_".join(stem.split("_")[:2]) if "alimeeting" in name.name else stem
            )
            held.append(
                (
                    "train" if "train" in name.name else "held",
                    f"{name.name}/{session}",
                    f,
                )
            )
    sessions = {}
    for s, key, f in held:
        sessions.setdefault((s, key), []).extend(textgrid(f))
    out = []
    n = 0
    for (s, key), segs in sorted(sessions.items()):
        if s == "held":
            s, n = ("dev", "test")[n % 2], n + 1
        out.append((s, key, [MARKS.sub("", t) for _, t in sorted(segs)]))
    return out


def textgrid(path):
    """(start, text) of each interval with text in a TextGrid's tiers."""
    segs, start = [], None
    for line in open(path, encoding="utf-8", errors="replace"):
        line = line.strip()
        if line.startswith("xmin ="):
            start = float(line.split("=")[1])
        elif line.startswith("text =") and '"' in line:
            t = line.split('"', 1)[1].rsplit('"', 1)[0]
            if t.strip():
                segs.append((start, t))
    return segs


def hundredcv(src):
    """HundredCV-Chat's dialogues, its subsample of training (pack.py's MIX) being its own; a turn that opens
    with the other's persona name (嗨，吴杰) goes: its names come from résumés, not from the text."""
    for i, line in enumerate(
        open(Path(src, "hundredcv-chat/synthesized_.jsonl"), encoding="utf-8")
    ):
        d = json.loads(line)
        names = [d.get("user1", ""), d.get("user2", "")]
        turns = [re.sub(r"^user[12][：:]", "", t) for t in d["dialog"]]
        yield i, [t for t in turns if not any(n and n in t[:10] for n in names)]


KD_DROP = re.compile(r"[0-9０-９]|地址|电话|位于")


def kdconv(src):
    """KdConv's dialogues, only the turns that answer from no knowledge-base entry (questions and reactions):
    the others paraphrase it (dates, awards, prices), and so do long turns or turns with digits or addresses."""
    for f in sorted(glob.glob(f"{src}/kdconv/*/*.json")):
        domain = Path(f).parent.name
        for i, d in enumerate(json.load(open(f, encoding="utf-8"))):
            yield (
                f"{domain}/{Path(f).stem}/{i}",
                [
                    m["message"]
                    for m in d["messages"]
                    if not m.get("attrs")
                    and len(m["message"]) <= 40
                    and not KD_DROP.search(m["message"])
                ],
            )


def tatoeba(src):
    """Tatoeba's Mandarin sentences, each its own document (t2s in clean(): a third are traditional)."""
    with bz2.open(
        Path(src, "tatoeba/cmn_sentences_detailed.tsv.bz2"), "rt", encoding="utf-8"
    ) as f:
        for line in f:
            p = line.split("\t")
            if len(p) > 2:
                yield p[0], [p[2]]


# oasst2's assistant answers are lists, instructions and AI talk more often than chat: of them only the
# paragraphs that are none of those are kept; the users' messages are kept whole.
LIST = re.compile(r"^\s*(?:\d+[.、)）]|[-*•·])")
AI = re.compile(r"作为(?:一个)?(?:AI|人工智能)|语言模型|AI助手|我是.{0,10}助手|以下是")


def oasst2(src):
    """oasst2's Chinese message trees, as their kept paragraphs."""
    trees = {}
    with gzip.open(
        Path(src, "oasst2/2023-11-05_oasst2_all.messages.jsonl.gz"),
        "rt",
        encoding="utf-8",
    ) as f:
        for m in map(json.loads, f):
            if m.get("lang") != "zh":
                continue
            paras = [p for p in m["text"].split("\n") if p.strip()]
            if m.get("role") == "assistant":
                paras = [p for p in paras if not LIST.match(p) and not AI.search(p)]
            trees.setdefault(m["message_tree_id"], []).extend(paras)
    yield from sorted(trees.items())


def chat(src):
    """(source, split, key, turns) of every chat document."""
    for s, key, turns in meetings(src):
        yield "meetings", s, key, turns
    for name, docs in (
        ("hundredcv", hundredcv),
        ("tatoeba", tatoeba),
        ("kdconv", kdconv),
        ("oasst2", oasst2),
    ):
        for key, turns in docs(src):
            yield name, split(name, key), key, turns


def clauses(s):
    """(start, clause) for each run of Han characters in S."""
    return [(m.start(), m.group()) for m in HAN_RUN.finditer(s)]


# --- pinyin ---------------------------------------------------------------------------------------------

FROST_DICTS = [
    "base",
    "ext",
    "8105",
    "41448",
]  # 白霜 core's word lists (data/rime/build.sh's FROST_CORE)


def make_readings(frost_zip, out):
    """Writes OUT: each word and character of 白霜's dictionary (rime-frost-schemas.zip) that pypinyin reads
    otherwise than the dictionary does, with the dictionary's likeliest reading (很长 hen chang; 嗯 en, where
    pypinyin has n, which Rime doesn't take)."""
    import zipfile

    from pypinyin import Style, lazy_pinyin

    reads = {}
    with zipfile.ZipFile(frost_zip) as z:
        for name in FROST_DICTS:
            body = z.read(f"cn_dicts/{name}.dict.yaml").decode().split("\n...\n", 1)[1]
            for line in body.splitlines():
                p = line.split("\t")
                if len(p) < 2 or line.startswith("#") or not HAN_RUN.fullmatch(p[0]):
                    continue
                weight = int(p[2]) if len(p) > 2 and p[2].isdigit() else 0
                r = reads.setdefault(p[0], {})
                r[p[1]] = max(r.get(p[1], -1), weight)
    n = 0
    with open(out, "w", encoding="utf-8") as f:
        for w, r in sorted(reads.items()):
            if " ".join(lazy_pinyin(w, style=Style.NORMAL)) not in r:
                f.write(f"{w}\t{max(r, key=r.get)}\n")
                n += 1
    print(
        f"readings: {n} of {len(reads)} words and characters read otherwise than pypinyin",
        flush=True,
    )


def use_readings(path):
    """pypinyin reads the words and characters of make_readings()'s file as 白霜's dictionary does."""
    from pypinyin import load_phrases_dict, load_single_dict

    rows = [l.split("\t") for l in Path(path).read_text(encoding="utf-8").splitlines()]
    load_phrases_dict({w: [[x] for x in r.split(" ")] for w, r in rows if len(w) > 1})
    load_single_dict({ord(w): r for w, r in rows if len(w) == 1})


def syllables(text):
    """One pinyin syllable per character of TEXT, all Han. Read a whole clause, then slice it: a word's
    reading depends on the characters after it (重庆 chong, 重 alone zhong)."""
    from pypinyin import Style, lazy_pinyin

    p = lazy_pinyin(text, style=Style.NORMAL, errors=lambda x: ["?"] * len(x))
    return (
        p
        if len(p) == len(text) and all(x.isalpha() and x.isascii() for x in p)
        else None
    )


def reading(text):
    """Each character's syllable, read for its whole clause (None outside one, or where pypinyin has none)."""
    out = [None] * len(text)
    for start, c in clauses(text):
        sy = syllables(c)
        if sy:
            out[start : start + len(c)] = sy
    return out


def initial(syllable, whole=False):
    """The first letter, or with WHOLE zh, ch or sh: rime-ice takes both as an abbreviation (chsh → 城市)."""
    return syllable[:2] if whole and syllable[:2] in ("zh", "ch", "sh") else syllable[0]


def abbreviated(sy, whole=False):
    """Each syllable's first letter: 知道 → zd, as rime-ice's abbreviations take it (WHOLE: initial())."""
    return "".join(initial(x, whole) for x in sy)


def partial(sy):
    """Full pinyin but the last syllable's first letter: 然后 → ranh."""
    return "".join(sy[:-1]) + initial(sy[-1])


def ue(keys):
    """lve and nve as most people type them, lue and nue: Rime takes both (rime-ice's speller)."""
    return re.sub(r"([ln])ve", r"\1ue", keys)


# --- typos ----------------------------------------------------------------------------------------------

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
PHONE = {
    k: ((i + (0, 0.5, 1.5)[r]) * 108 + 54, r * 160 + 80)
    for r, row in enumerate(ROWS)
    for i, k in enumerate(row)
}
SIGMA_PX = 1.9 / (6.8 / 108)
CONFUSIONS = [("zh", "z"), ("ch", "c"), ("sh", "s"), ("ng", "n")]
# Of the typos: the phone mix of #46 (slips, missing, extra, swapped as 55.6 : 33.3 : 11.1 of 94 %, swaps 6 %),
# with a fifth of them a pinyin confusion instead. An extra letter is the key doubled or a slip next to it.
KINDS = ["slip", "omit", "double", "swap", "confuse"]
WEIGHTS = [55.6 * 0.94 * 0.8, 33.3 * 0.94 * 0.8, 11.1 * 0.94 * 0.8, 6 * 0.8, 20]
# The app's other fuzzy pinyin pairs (ChineseData.kt), initials either way: with one on, Rime offers 南京 for
# lanjing, and the model has to read it so too (#557). Rarer than the confusions above, and only in training
# (typo()'s FUZZY): the harness's typo set stays as it was, and its variants set measures these.
FUZZY = [("l", "n"), ("f", "h"), ("r", "l"), ("k", "g")]
FUZZY_WEIGHT = 5


def slip(rng, k):
    if k not in PHONE:
        return k
    while True:
        x, y = PHONE[k]
        tx, ty = rng.gauss(x, SIGMA_PX), rng.gauss(y, SIGMA_PX)
        j = min(PHONE, key=lambda c: (PHONE[c][0] - tx) ** 2 + (PHONE[c][1] - ty) ** 2)
        if j != k:
            return j


def confuse(rng, sy):
    """One syllable's zh/z, ch/c, sh/s or ng/n turned into the other, or None when it has none."""
    options = []
    for i, x in enumerate(sy):
        for full, short in CONFUSIONS:
            if full in ("zh", "ch", "sh"):
                if x.startswith(full):
                    options.append((i, short + x[2:]))
                elif x.startswith(short) and not x.startswith(short + "h"):
                    options.append((i, full + x[1:]))
            elif x.endswith("ng"):
                options.append((i, x[:-1]))
            elif x.endswith("n") and x[-2:] in ("an", "en", "in"):
                options.append((i, x + "g"))
    if not options:
        return None
    i, y = rng.choice(options)
    return sy[:i] + [y] + sy[i + 1 :]


def fuzzy(rng, sy):
    """One syllable's initial l/n, f/h, r/l or k/g turned into the other, or None when it has none."""
    options = [
        (i, b + x[1:])
        for i, x in enumerate(sy)
        for p in FUZZY
        for a, b in (p, p[::-1])
        if x.startswith(a) and not (a == "n" and x.startswith("ng"))
    ]
    if not options:
        return None
    i, y = rng.choice(options)
    return sy[:i] + [y] + sy[i + 1 :]


def typo(rng, sy, kind=None, fuzzy_pairs=False):
    """KEYS for the syllables SY with one typo of KIND (drawn from the mix when None, with FUZZY_PAIRS the
    app's other fuzzy pairs among them), and the kind."""
    kind = (
        kind
        or rng.choices(KINDS + ["fuzzy"], WEIGHTS + [FUZZY_WEIGHT * fuzzy_pairs])[0]
    )
    if kind in ("confuse", "fuzzy"):
        c = (confuse if kind == "confuse" else fuzzy)(rng, sy)
        if c:
            return "".join(c), kind
        kind = "slip"
    s = "".join(sy)
    i = rng.randrange(len(s))
    if kind == "slip":
        return s[:i] + slip(rng, s[i]) + s[i + 1 :], kind
    if kind == "omit":
        return (s[:i] + s[i + 1 :] if len(s) > 1 else s), kind
    if kind == "double":
        extra = s[i] if rng.random() < 0.5 else slip(rng, s[i])
        return s[:i] + extra + s[i:], kind
    js = [p for p in range(len(s) - 1) if s[p] != s[p + 1]]
    if not js:
        return s[:i] + slip(rng, s[i]) + s[i + 1 :], "slip"
    i = rng.choice(js)
    return s[:i] + s[i + 1] + s[i] + s[i + 2 :], kind


if __name__ == "__main__":
    # common.py readings FROST_ZIP OUT
    import sys

    assert sys.argv[1] == "readings"
    make_readings(*sys.argv[2:4])
