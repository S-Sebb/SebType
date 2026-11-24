"""Makes the dev sets that tune.py tunes the ranking on, in the harness's format, from the corpus's held-out
lines (corpus.py's *.dev.txt), never from the harness's test sets.

  dev_sets.py RUN_DIR

Writes RUN_DIR/dev/{next-chat,next-news,clean,phone-typos,misspellings,next-texts,text-typos,apostrophes,
capitals,homographs,parity}.tsv: chat from
oasst2 and Dolly, news from Wikinews, as in the harness's register (SODA's chit-chat has too few words the
dictionary lacks to tune the autocorrection on), typed with the harness's touch and typo model (make_sets.py). The typed sets take every
word of their sentences, 70 % of each source's words clean, 30 % with typos. The misspellings are noise.py's
spelling mistakes with no context. The texting sets come from NUS SMS messages, as the harness's do: every
lowercase word of 200 messages, and one typo in a word of three letters or more of each of the others, each
target the word its letters mean (make_sets.py's intended(): "dont" is "don't").
#556's: apostrophes and capitals as the harness's (make_sets.py's sentence_rows()), from the held-out lines of
the chat sources and Wikinews; homographs, every bare form that is a word too ("its", "well") in those lines,
typed as it is, and every contraction it is the bare form of ("it's", "we'll"), typed without its apostrophe.
A query whose last SEEN_WORDS words are in a training file (*.txt) is left out of every set; the count is
printed. parity.tsv is parity.py's fixture (parity_rows()).
"""

import multiprocessing as mp
import random
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "android/test/english"))
# Run with python -I, which drops the script's own folder from the path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_sets import (
    WORD,
    dictionary,
    intended_of,
    row,
    sentence_rows,
    sentences,
    tap,
    targets,
    typo,
)
from noise import spelling

# A query (its context and target) whose last SEEN_WORDS words are in a training file is left out: a phrase that
# long ending at the target is the sentence itself, or a copy of it, which the model may have learnt by heart.
# Six words also drop everyday phrases any chat has ("i don't know what i'm"); see #556.
SEEN_WORDS = 8
WORDS = re.compile(r"[a-z0-9']+")
tails = None


def query(r):
    """Row R's context and target, as lowercase words."""
    context, _, target = r.split("\t")[:3]
    return tuple(WORDS.findall(f"{context} {target}".lower()))


def scan(part):
    """The tails (global) found in the lines of the byte range PART = (path, start, end)."""
    path, start, end = part
    found = set()
    with open(path, "rb") as f:
        f.seek(start)
        if start:
            f.readline()
        while f.tell() <= end:
            line = f.readline()
            if not line:
                break
            w = WORDS.findall(line.decode().lower())
            if len(w) >= SEEN_WORDS:
                found |= tails.intersection(zip(*(w[i:] for i in range(SEEN_WORDS))))
    return found


def seen(corpus, sets):
    """The last SEEN_WORDS words of SETS' queries that occur in a training file of CORPUS."""
    global tails
    tails = {
        q[-SEEN_WORDS:] for rows in sets.values() for r in rows for q in [query(r)]
    }
    tails = {t for t in tails if len(t) == SEEN_WORDS}
    size = 64 << 20
    parts = [
        (str(f), s, s + size)
        for f in sorted(corpus.glob("*.txt"))
        if not f.name.endswith(".dev.txt")
        for s in range(0, f.stat().st_size, size)
    ]
    with mp.Pool(32, initializer=set_tails, initargs=(tails,)) as pool:
        return set().union(*pool.imap_unordered(scan, parts))


def set_tails(t):
    global tails
    tails = t


def main(run):
    corpus, out = Path(run) / "data/corpus", Path(run) / "dev"
    out.mkdir(exist_ok=True)
    rng = random.Random(2361)
    read = lambda *names: [
        l for n in names for l in (corpus / f"{n}.dev.txt").read_text().splitlines()
    ]
    sets = {}
    chat = [
        s for s in dict.fromkeys(sentences(read("oasst2", "dolly"))) if any(targets(s))
    ]
    news = [s for s in dict.fromkeys(sentences(read("wikinews"))) if any(targets(s))]
    rng.shuffle(chat)
    rng.shuffle(news)
    sets["next-chat"] = [row(c, "", w) for s in chat[:150] for c, w in targets(s)]
    sets["next-news"] = [row(c, "", w) for s in news[:100] for c, w in targets(s)]
    clean, typos, pool = [], [], []
    for sents in (chat[150:], news[100:]):
        words = [t for s in sents for t in targets(s)]
        cut = len(words) * 7 // 10
        clean += words[:cut]
        typos += [t for t in words[cut:] if len(t[1]) >= 3]
        pool += words
    sets["clean"] = [row(c, w, w, [tap(rng, ch, True) for ch in w]) for c, w in clean]
    sets["phone-typos"] = [
        row(c, t, w, taps) for c, w in typos for t, taps in [typo(rng, w)]
    ]
    words = sorted({w for _, w in pool if len(w) >= 5})
    pairs = [(m, w) for w in rng.sample(words, 1500) for m in [spelling(rng, w)] if m]
    sets["misspellings"] = [
        row("", m, w, [tap(rng, ch, True) for ch in m]) for m, w in pairs
    ]
    words = dictionary()
    intended = intended_of(words)
    everyday = list(
        dict.fromkeys(
            sentences(
                read("oasst2", "dolly", "soda", "bst", "topical-chat", "wikinews")
            )
        )
    )
    sets["apostrophes"], sets["capitals"] = sentence_rows(
        rng, everyday, words, 400, 400
    )
    homographs = {
        "its",
        "were",
        "well",
        "hell",
        "shell",
        "shed",
        "wed",
        "ill",
        "id",
        "lets",
        "cant",
        "wont",
    }
    rows = []
    for s in everyday:
        for m in WORD.finditer(s):
            bare = m.group().replace("'", "").lower()  # "I'll" is typed "ill"
            if (
                bare in homographs
                and m.start() > 0
                and s[m.end() : m.end() + 1] in ("", *" .,!?;:")
            ):
                rows.append(
                    row(
                        s[: m.start()].rstrip(),
                        bare,
                        m.group(),
                        [tap(rng, ch, True) for ch in bare],
                    )
                )
    rng.shuffle(rows)
    sets["homographs"] = rows[:400]
    texts = [
        t
        for t in dict.fromkeys(read("nus-sms"))
        if 3 <= len(t.split()) <= 30 and any(len(w) >= 3 for _, w in targets(t, 1))
    ]
    rng.shuffle(texts)
    sets["next-texts"] = [
        row(c, "", intended(w)) for t in texts[:200] for c, w in targets(t, 1)
    ]
    sets["text-typos"] = [
        row(c, typed, intended(w), taps)
        for t in texts[200:]
        for c, w in [rng.choice([x for x in targets(t, 3)])]
        for typed, taps in [typo(rng, w)]
    ]
    found = seen(corpus, sets)
    for name, rows in sets.items():
        sets[name] = [r for r in rows if query(r)[-SEEN_WORDS:] not in found]
        print(
            f"{name}.tsv: {len(sets[name])} rows, {len(rows) - len(sets[name])} left out as in training"
        )
    sets["parity"] = parity_rows(rng, sets, read("oasst2", "dolly", "soda", "wikinews"))
    print(f"parity.tsv: {len(sets['parity'])} rows")
    for name, rows in sets.items():
        (out / f"{name}.tsv").write_text("".join(r + "\n" for r in rows))


def parity_rows(rng, sets, lines):
    """parity.py's fixture: rows of the sets with what scoring treats differently (a capital target, an
    empty context, a contraction typed bare, a bare form that is a word too), and contexts longer than the
    phone's window (CONTEXT_CHARS), from long held-out lines, which no other set has."""
    out = [
        r
        for n in ("clean", "capitals", "apostrophes", "homographs", "misspellings")
        for r in rng.sample(sets[n], min(30, len(sets[n])))
    ]
    long = [l for l in lines if len(l) > 400 and l.isascii()]
    rng.shuffle(long)
    for l in long[
        :30
    ]:  # one row per line: the phone's window then depends on the line alone
        c, w = rng.choice([t for t in targets(l) if len(t[0]) > 300] or [("", "")])
        if w:
            out.append(row(c, w, w, [tap(rng, ch, True) for ch in w]))
    return out


if __name__ == "__main__":
    main(sys.argv[1])
