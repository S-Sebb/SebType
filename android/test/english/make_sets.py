"""Builds the English harness's test sets (#231) from openly licensed text; run.sh reads the committed result.

  make_sets.py OASST1_PROMPTS_JSONL_GZ MISSPELLINGS_TXT WIKINEWS_JSON OUT_DIR
  make_sets.py texts NUS_SMS_XML OUT_DIR

WIKINEWS_JSON is a cache: fetched from Wikinews's API when it doesn't exist.

Sentences come from OpenAssistant oasst1's prompts (chat, Apache-2.0) and the last English Wikinews articles
(news, CC BY 2.5); misspellings from Wikipedia's machine-readable list (CC BY-SA 4.0). Each set is a TSV:
context, typed letters, intended word, then the touch points' x and y (comma-separated, layout.tsv's pixels).

- next-chat, next-news: every lowercase word after the first in 250 chat and 150 news sentences, with nothing
  typed: the next word to predict.
- clean: 1,000 such words typed with touch noise that stays on the intended keys.
- phone-typos: 1,000 such words with one typo, or two in 10 % of them, in #46's phone mix (Palin et al.
  MobileHCI 2019): substitution 55.6 %, omission 33.3 %, insertion 11.1 % of the other errors; 6 % swaps.
  A substitution or a neighbour insertion is a tap that lands on another key.
- misspellings: 1,500 of Wikipedia's common misspellings, typed on their own keys with no context.

The sets #556 added, for what those can't see: every target above is a lowercase word without an apostrophe.
On the phone the apostrophe isn't on the letter layer, so a contraction is typed without it.
- contractions: the 77 contractions of #539's sweep, each typed without its apostrophe after four contexts:
  none (a sentence start, typed with the shift on), "So", and the texting "lol ok" and "yeah but". The 7 whose
  bare form is a word of its own (its, were, well, hell, shell, shed, wed) are in homographs instead.
- homographs: bare forms that are words of their own, after contexts that mean the word ("She was very ill")
  or the contraction ("I think its"): HOMOGRAPHS below.
- apostrophes: 400 of those contractions in chat and news sentences after the word sets', whose bare form
  means them (intended() below), typed without the apostrophe; half with a typo as phone-typos.
- capitals: 400 capitalised words of those sentences: half their first word, typed with the shift on, and half
  a capitalised word in mid-sentence that the dictionary only has so ("I", "Paris", "Monday"), typed in lowercase;
  half of each with a typo.

`texts` makes the texting sets (#266) from real text messages, the NUS SMS Corpus (CC BY 4.0), as their senders
wrote them: lowercase, "u", "lol", "dont". Only senders from the US, Canada, the UK, Australia and New Zealand,
as the rest is mostly Singaporean and Indian English. No sender gives more than 15 % of the messages.
- next-texts: every lowercase word after the first in 400 messages, one letter or longer, nothing typed.
- text-typos: one word of three letters or more from each of 1,000 other messages, with a typo as phone-typos.
A word typed without its apostrophe ("dont", "im") is meant as the word with it ("don't", "I'm") when the
dictionary has only that one. nus-sms-held-out.txt lists the messages' ids: tools/english-lm/corpus.py leaves
them out of training, and every message with the same words.
Personal data: the corpus already replaced numbers and email addresses (<#>, <EMAIL>); a message is left out if
it has a digit, a placeholder or one of @#/<>_, a capital in mid-sentence (other than I), a word that is a name
more often than not in data/en-dict/en_US.dict ("John", "Mike", "Monday"), or a word that is in neither the
dictionary nor the messages of 5 senders (a friend's name, a street).

Taps are a Gaussian around the key centre with sigma 30 px (1.9 mm on #46's 108 px, 6.8 mm keys). Each set
uses its own sentences; the seed is fixed, so the same inputs give the same files.
"""

import gzip
import json
import random
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
SIGMA = 30.0
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
ASCII = str.maketrans(
    {"‘": "'", "’": "'", "“": '"', "”": '"', "–": "-", "—": "-", " ": " "}
)


def load_layout():
    keys = []
    for line in (HERE / "layout.tsv").read_text().splitlines():
        if line and not line.startswith("#"):
            k, x, y, w, h = line.split("\t")
            keys.append((k, int(x), int(y), int(w), int(h)))
    return keys


KEYS = load_layout()
LETTERS = {k: (x, y, w, h) for k, x, y, w, h in KEYS if len(k) == 1 and k.isalpha()}


def key_at(x, y):
    for k, kx, ky, w, h in KEYS:
        if kx <= x < kx + w and ky <= y < ky + h:
            return k
    return None


def dictionary():
    """data/en-dict/en_US.dict's words: word -> (frequency, not a word, offensive, shortcuts)."""
    sys.path.insert(
        0, str(HERE.parents[2] / "data/en-dict")
    )  # run with python3 -I, which drops it
    import v202

    return v202.decode((HERE.parents[2] / "data/en-dict/en_US.dict").read_bytes())[1]


def intended_of(words):
    """intended(w): the word meant by W typed without its apostrophe ("dont": "don't", "im": "I'm"), when the
    dictionary has only one such word (case aside, preferring its lowercase form) and W is no word itself or has
    it as its shortcut ("ill": "I'll"); otherwise W."""
    freq = lambda w: words[w][0] if w in words and not words[w][1] else -1
    forms = defaultdict(dict)
    for a, (_, not_a_word, _, _) in words.items():
        if "'" in a and not not_a_word:
            forms[a.replace("'", "").lower()].setdefault(a.lower(), a)
    for d in forms.values():
        for k in d:
            if k in words and not words[k][1]:
                d[k] = k

    def intended(w):
        found = list(forms.get(w, {}).values())
        shortcuts = [t for t, _ in words[w][3]] if w in words else []
        return (
            found[0]
            if len(found) == 1 and (freq(w) < 0 or found[0] in shortcuts)
            else w
        )

    return intended


def tap(rng, letter, on_key):
    """A tap aimed at LETTER: on its key if ON_KEY, else on another letter's key. Returns (key, x, y)."""
    x, y, w, h = LETTERS[letter]
    while True:
        px, py = round(rng.gauss(x + w / 2, SIGMA)), round(rng.gauss(y + h / 2, SIGMA))
        k = key_at(px, py)
        if k in LETTERS and (k == letter) == on_key:
            return k, px, py


def sentences(texts):
    for text in texts:
        for s in re.split(r"(?<=[.!?])\s+|\n+", text.translate(ASCII)):
            s = s.strip()
            if (
                s.isascii()
                and 5 <= len(s.split()) <= 30
                and s[0].isupper()
                and s[-1] in ".!?"
                and not re.search(r"https?:|www\.|[`{}<>|@#*_\[\]\\]", s)
            ):
                yield s


def targets(s, min_len=2):
    """(context, word) for each lowercase word after the first that stands alone between spaces/punctuation."""
    for m in WORD.finditer(s):
        w, i, j = m.group(), m.start(), m.end()
        if (
            i > 0
            and s[i - 1] == " "
            and w.isalpha()
            and w.islower()
            and len(w) >= min_len
            and (j == len(s) or s[j] in " .,!?;:")
        ):
            yield s[:i].rstrip(), w


def row(context, typed, target, taps=()):
    return "\t".join(
        (
            context,
            typed,
            target,
            ",".join(str(x) for _, x, _ in taps),
            ",".join(str(y) for _, _, y in taps),
        )
    )


def typo(rng, word):
    """WORD typed with one error, or two in 10 % of words; returns the taps, never WORD itself."""
    while True:
        taps = [tap(rng, c, True) for c in word]
        for _ in range(2 if rng.random() < 0.10 else 1):
            i = rng.randrange(len(taps))
            r = rng.random()
            if r < 0.06 and len(taps) > 1:  # swap with the next letter
                i = min(i, len(taps) - 2)
                taps[i], taps[i + 1] = taps[i + 1], taps[i]
            elif (
                r < 0.06 + 0.94 * 0.556
            ):  # substitution: the tap slips onto another key
                taps[i] = tap(rng, taps[i][0], False)
            elif r < 0.06 + 0.94 * (0.556 + 0.333) and len(taps) > 1:  # omission
                del taps[i]
            elif rng.random() < 0.5:  # insertion: the same key twice
                taps.insert(i, tap(rng, taps[i][0], True))
            else:  # insertion: a neighbour hit with the intended key
                taps.insert(i + rng.randrange(2), tap(rng, taps[i][0], False))
        typed = "".join(k for k, _, _ in taps)
        if typed != word:
            return typed, taps


def fetch_wikinews(path, n=200):
    """The last N articles published on English Wikinews (closed in 2026, so the list no longer changes)."""

    def get(**params):
        url = "https://en.wikinews.org/w/api.php?" + urllib.parse.urlencode(
            {"format": "json", **params}
        )
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "SebType-english-harness/1.0 (S-Sebb/SebType#231)"},
        )
        for wait in (2, 10, 30, 60, 120):
            time.sleep(wait)
            try:
                return json.load(urllib.request.urlopen(req, timeout=60))
            except urllib.error.HTTPError as e:
                if e.code != 429:
                    raise
        raise RuntimeError(f"Wikinews keeps answering 429 to {url}")

    titles, cont = [], {}
    while len(titles) < n:
        r = get(
            action="query",
            list="categorymembers",
            cmtitle="Category:Published",
            cmtype="page",
            cmsort="timestamp",
            cmdir="desc",
            cmlimit=50,
            **cont,
        )
        titles += [m["title"] for m in r["query"]["categorymembers"]]
        cont = r["continue"]
    articles = []
    for t in titles[:n]:
        page = next(
            iter(
                get(
                    action="query",
                    prop="extracts|revisions",
                    explaintext=1,
                    rvprop="ids",
                    titles=t,
                )["query"]["pages"].values()
            )
        )
        articles.append(
            {
                "title": t,
                "revid": page["revisions"][0]["revid"],
                "text": page["extract"],
            }
        )
    Path(path).write_text(json.dumps(articles))


def main(oasst, misspellings, wikinews, out):
    out = Path(out)
    if not Path(wikinews).exists():
        fetch_wikinews(wikinews)
    rng = random.Random(231)
    chat_texts = [
        m["text"]
        for m in map(
            json.loads, gzip.decompress(Path(oasst).read_bytes()).decode().splitlines()
        )
        if m.get("lang") == "en"
    ]
    news = json.loads(Path(wikinews).read_text())
    chat = list(dict.fromkeys(sentences(chat_texts)))
    news_s = list(dict.fromkeys(sentences(a["text"] for a in news)))
    rng.shuffle(chat)
    rng.shuffle(news_s)
    chat = [s for s in chat if any(targets(s))]
    news_s = [s for s in news_s if any(targets(s))]

    sets = {"next-chat": chat[:250], "next-news": news_s[:150]}
    for name, pool in sets.items():
        (out / f"{name}.tsv").write_text(
            "".join(row(c, "", w) + "\n" for s in pool for c, w in targets(s))
        )

    # Word sets: one word from each of their own sentences, 60 % chat and 40 % news, none shared with another set.
    cursor = {"chat": 250, "news": 150}
    pools = {"chat": chat, "news": news_s}

    def words(n, min_len):
        picked = []
        for source, count in (("chat", n * 6 // 10), ("news", n - n * 6 // 10)):
            got = 0
            while got < count:
                s = pools[source][cursor[source]]
                cursor[source] += 1
                ts = [t for t in targets(s) if len(t[1]) >= min_len]
                if ts:
                    picked.append(rng.choice(ts))
                    got += 1
        return picked

    clean = words(1000, 2)
    (out / "clean.tsv").write_text(
        "".join(row(c, w, w, [tap(rng, ch, True) for ch in w]) + "\n" for c, w in clean)
    )
    typos = words(1000, 3)
    (out / "phone-typos.tsv").write_text(
        "".join(
            row(c, t, w, taps) + "\n" for c, w in typos for t, taps in [typo(rng, w)]
        )
    )

    pairs = sorted(
        {
            (a, b)
            for a, b in (
                line.strip().split("->", 1)
                for line in Path(misspellings).read_text().splitlines()
                if "->" in line
            )
            if a.isalpha()
            and b.isalpha()
            and a.islower()
            and b.islower()
            and len(a) >= 3
        }
    )
    picked = rng.sample(pairs, 1500)
    (out / "misspellings.tsv").write_text(
        "".join(
            row("", a, b, [tap(rng, ch, True) for ch in a]) + "\n" for a, b in picked
        )
    )
    (out / "wikinews-articles.tsv").write_text(
        "".join(f"{a['revid']}\t{a['title']}\n" for a in news)
    )
    # #556's sets, from the sentences after the word sets' and with their own seed, so the sets above stay
    # as they were measured.
    contraction_sets(out, [pools[k][cursor[k] :] for k in ("chat", "news")])
    for f in sorted(out.glob("*.tsv")):
        print(f"{f.name}: {len(f.read_text().splitlines())} rows")


# #539's sweep: the dictionary's contractions (isContraction in core/src/english.cpp).
CONTRACTIONS = [
    "ain't",
    "aren't",
    "can't",
    "couldn't",
    "could've",
    "daren't",
    "didn't",
    "doesn't",
    "don't",
    "hadn't",
    "hasn't",
    "haven't",
    "he'd",
    "he'll",
    "here's",
    "he's",
    "how's",
    "I'd",
    "I'll",
    "I'm",
    "isn't",
    "it'd",
    "it'll",
    "it's",
    "I've",
    "let's",
    "ma'am",
    "mayn't",
    "mightn't",
    "might've",
    "mustn't",
    "must've",
    "needn't",
    "o'clock",
    "oughtn't",
    "shan't",
    "she'd",
    "she'll",
    "she's",
    "shouldn't",
    "should've",
    "that'd",
    "that'll",
    "that's",
    "there'd",
    "there'll",
    "there're",
    "there's",
    "they'd",
    "they'll",
    "they're",
    "they've",
    "wasn't",
    "we'd",
    "we'll",
    "we're",
    "weren't",
    "we've",
    "what'd",
    "what'll",
    "what're",
    "what's",
    "when's",
    "where's",
    "who'd",
    "who'll",
    "who's",
    "who've",
    "why's",
    "won't",
    "wouldn't",
    "would've",
    "y'all",
    "you'd",
    "you'll",
    "you're",
    "you've",
]
CONTRACTED = {w.lower() for w in CONTRACTIONS}
CONTRACTION_CONTEXTS = ("", "So", "lol ok", "yeah but")
# Bare forms that are words too: context, typed, the word meant. The context alone tells which.
HOMOGRAPHS = [
    ("The company raised", "its", "its"),
    ("The dog wagged", "its", "its"),
    ("I think", "its", "it's"),
    ("They", "were", "were"),
    ("Where", "were", "were"),
    ("I hope", "were", "we're"),
    ("She sings very", "well", "well"),
    ("Oh", "well", "well"),
    ("I promise", "well", "we'll"),
    ("What the", "hell", "hell"),
    ("It was a living", "hell", "hell"),
    ("I'm sure", "hell", "he'll"),
    ("The turtle hid in its", "shell", "shell"),
    ("I found a sea", "shell", "shell"),
    ("I hope", "shell", "she'll"),
    ("The tools are in the garden", "shed", "shed"),
    ("Snakes", "shed", "shed"),
    ("I think", "shed", "she'd"),
    ("The couple will be", "wed", "wed"),
    ("If we left now", "wed", "we'd"),
    ("She was very", "ill", "ill"),
    ("He fell", "ill", "ill"),
    ("ok", "ill", "I'll"),
    ("Freud wrote about the ego and the", "id", "id"),
    ("If I were you", "id", "I'd"),
    ("She never", "lets", "lets"),
    ("He", "lets", "lets"),
    ("ok", "lets", "let's"),
    ("As is his", "wont", "wont"),
    ("I", "wont", "won't"),
    ("I", "cant", "can't"),
]


def typed_as(rng, word, typo_too):
    """WORD's letters without apostrophes, in its case, on their keys or with a typo if TYPO_TOO."""
    bare = word.replace("'", "")
    if not typo_too or len(bare) < 2:
        return bare, [tap(rng, ch, True) for ch in bare.lower()]
    t, taps = typo(rng, bare.lower())
    return (t[0].upper() + t[1:] if bare[0].isupper() else t), taps


def sentence_rows(rng, sents, words, n_apostrophes, n_capitals):
    """From SENTS (shuffled here): N_APOSTROPHES rows of a contraction typed without its apostrophe, and
    N_CAPITALS / 2 each of a first word typed with the shift on and of a mid-sentence word the dictionary only
    has capitalised, typed in lowercase; every other one of each kind with a typo."""
    intended = intended_of(words)
    sents = list(sents)
    rng.shuffle(sents)
    apostrophes, starts, middles = [], [], []
    for s in sents:
        ms = [
            m for m in WORD.finditer(s) if s[m.end() : m.end() + 1] in ("", *" .,!?;:")
        ]
        found = [
            m
            for m in ms
            if m.group().lower() in CONTRACTED
            and intended(m.group().replace("'", "").lower())
            in (m.group(), m.group().lower())
        ]
        if found and len(apostrophes) < n_apostrophes:
            m = rng.choice(found)
            t, taps = typed_as(rng, m.group(), len(apostrophes) % 2)
            apostrophes.append(row(s[: m.start()].rstrip(), t, m.group(), taps))
            continue
        first = ms[0] if ms and ms[0].start() == 0 else None
        # "I" is in most sentences: a quarter of the mid-sentence capitals at most.
        only_capitalised = lambda w: (
            w[0].isupper()
            and (
                w[1:].islower()
                or (w == "I" and sum("\tI\t" in r for r in middles) < n_capitals // 8)
            )
            and w in words
            and not words[w][1]
            and (w.lower() not in words or words[w.lower()][1])
        )
        mid = [
            m
            for m in ms[1:]
            if only_capitalised(m.group()) and s[: m.start()].rstrip()[-1:] not in ".!?"
        ]
        if mid and len(middles) < n_capitals // 2:
            m = rng.choice(mid)
            t, taps = typed_as(rng, m.group().lower(), len(middles) % 2)
            middles.append(row(s[: m.start()].rstrip(), t, m.group(), taps))
        elif (
            first
            and first.group().isalpha()
            and len(first.group()) >= 2
            and len(starts) < n_capitals // 2
        ):
            t, taps = typed_as(rng, first.group(), len(starts) % 2)
            starts.append(row("", t, first.group(), taps))
    return apostrophes, starts + middles


def contraction_sets(out, pools):
    """contractions, homographs, apostrophes and capitals (the docstring); POOLS: chat's and news's unused
    sentences."""
    rng = random.Random(556)
    words = dictionary()
    intended = intended_of(words)
    rows = []
    for w in CONTRACTIONS:
        if intended(w.replace("'", "").lower()) != w:
            continue
        for c in CONTRACTION_CONTEXTS:
            target = w[0].upper() + w[1:] if not c else w
            t, taps = typed_as(rng, target, False)
            rows.append(row(c, t, target, taps))
    (out / "contractions.tsv").write_text("".join(r + "\n" for r in rows))
    (out / "homographs.tsv").write_text(
        "".join(
            row(c, t, w, typed_as(rng, t, False)[1]) + "\n" for c, t, w in HOMOGRAPHS
        )
    )
    apostrophes, capitals = sentence_rows(
        rng, [s for p in pools for s in p], words, 400, 400
    )
    assert len(apostrophes) == len(capitals) == 400, (len(apostrophes), len(capitals))
    (out / "apostrophes.tsv").write_text("".join(r + "\n" for r in apostrophes))
    (out / "capitals.tsv").write_text("".join(r + "\n" for r in capitals))


NUS_COUNTRIES = {
    "united states",
    "usa",
    "canada",
    "united kingdom",
    "uk",
    "australia",
    "new zealand",
}
I_FORMS = {"I", "I'm", "I'll", "I'd", "I've"}


def texts(nus, out):
    out = Path(out)
    words = dictionary()
    freq = lambda w: words[w][0] if w in words and not words[w][1] else -1
    intended = intended_of(words)

    def name_like(w):
        cap = w.capitalize()
        return cap not in I_FORMS and cap in words and freq(w) < words[cap][0]

    msgs = []
    for m in ET.parse(nus).getroot().iter("message"):
        p = m.find("source/userProfile")
        text = " ".join((m.findtext("text") or "").translate(ASCII).split())
        msgs.append(
            (
                m.get("id"),
                p.findtext("userID"),
                p.findtext("country").strip().lower(),
                text,
            )
        )
    senders = defaultdict(set)
    for _, u, _, t in msgs:
        for w in WORD.findall(t.lower()):
            senders[w].add(u)

    def plain(t):
        ms = list(WORD.finditer(t))
        return (
            t.isascii()
            and 3 <= len(t.split()) <= 30
            and not re.search(r"[0-9<>@#/\\_*=|~^{}\[\]]|https?:|www\.", t)
            and all(
                (freq(w) >= 0 or len(senders[w]) >= 5) and not name_like(w)
                for w in (m.group().lower() for m in ms)
            )
            and not any(
                m.group()[0].isupper()
                and not m.group().isupper()
                and m.group() not in I_FORMS
                and t[: m.start()].strip()[-1:] not in ("", ".", "!", "?")
                for m in ms
            )
        )

    pool, seen = [], set()
    for i, u, c, t in msgs:
        if c in NUS_COUNTRIES and plain(t) and t.lower() not in seen:
            seen.add(t.lower())
            pool.append((i, u, t))
    rng = random.Random(266)
    rng.shuffle(pool)
    n_next, n_typos = 400, 1000
    cap, per_sender, picked = (n_next + n_typos) * 15 // 100, Counter(), []
    for i, u, t in pool:
        need = 1 if len(picked) < n_next else 3
        if per_sender[u] < cap and any(len(w) >= need for _, w in targets(t, 1)):
            per_sender[u] += 1
            picked.append((i, t))
            if len(picked) == n_next + n_typos:
                break
    assert len(picked) == n_next + n_typos, f"only {len(picked)} messages pass"
    (out / "next-texts.tsv").write_text(
        "".join(
            row(c, "", intended(w)) + "\n"
            for _, t in picked[:n_next]
            for c, w in targets(t, 1)
        )
    )
    rows = []
    for _, t in picked[n_next:]:
        c, w = rng.choice([x for x in targets(t, 3)])
        typed, taps = typo(rng, w)
        rows.append(row(c, typed, intended(w), taps) + "\n")
    (out / "text-typos.tsv").write_text("".join(rows))
    (out / "nus-sms-held-out.txt").write_text(
        "".join(f"{i}\n" for i in sorted(int(i) for i, _ in picked))
    )
    print(
        f"{len(pool)} messages pass, from {len({u for _, u, _ in pool})} senders; per sender {per_sender.most_common(5)}"
    )
    for f in ("next-texts.tsv", "text-typos.tsv"):
        print(f"{f}: {len((out / f).read_text().splitlines())} rows")


if __name__ == "__main__":
    if sys.argv[1] == "texts":
        texts(*sys.argv[2:])
    else:
        main(*sys.argv[1:])
