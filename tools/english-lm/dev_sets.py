"""Makes the dev sets that tune.py tunes the ranking on, in the harness's format, from the corpus's held-out
lines (corpus.py's *.dev.txt), never from the harness's test sets.

  dev_sets.py RUN_DIR

Writes RUN_DIR/dev/{next-chat,next-news,clean,phone-typos,misspellings,next-texts,text-typos}.tsv: chat from
oasst2 and Dolly, news from Wikinews, as in the harness's register (SODA's chit-chat has too few words the
dictionary lacks to tune the autocorrection on), typed with the harness's touch and typo model (make_sets.py). The typed sets take every
word of their sentences, 70 % of each source's words clean, 30 % with typos. The misspellings are noise.py's
spelling mistakes with no context. The texting sets come from NUS SMS messages, as the harness's do: every
lowercase word of 200 messages, and one typo in a word of three letters or more of each of the others.
"""

import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "android/test/english"))
# Run with python -I, which drops the script's own folder from the path.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from make_sets import row, sentences, tap, targets, typo
from noise import spelling


def main(run):
    corpus, out = Path(run) / "data/corpus", Path(run) / "dev"
    out.mkdir(exist_ok=True)
    rng = random.Random(2361)
    read = lambda *names: [
        l for n in names for l in (corpus / f"{n}.dev.txt").read_text().splitlines()
    ]
    chat = [
        s for s in dict.fromkeys(sentences(read("oasst2", "dolly"))) if any(targets(s))
    ]
    news = [s for s in dict.fromkeys(sentences(read("wikinews"))) if any(targets(s))]
    rng.shuffle(chat)
    rng.shuffle(news)
    (out / "next-chat.tsv").write_text(
        "".join(row(c, "", w) + "\n" for s in chat[:150] for c, w in targets(s))
    )
    (out / "next-news.tsv").write_text(
        "".join(row(c, "", w) + "\n" for s in news[:100] for c, w in targets(s))
    )
    clean, typos, pool = [], [], []
    for sents in (chat[150:], news[100:]):
        words = [t for s in sents for t in targets(s)]
        cut = len(words) * 7 // 10
        clean += words[:cut]
        typos += [t for t in words[cut:] if len(t[1]) >= 3]
        pool += words
    (out / "clean.tsv").write_text(
        "".join(row(c, w, w, [tap(rng, ch, True) for ch in w]) + "\n" for c, w in clean)
    )
    (out / "phone-typos.tsv").write_text(
        "".join(
            row(c, t, w, taps) + "\n" for c, w in typos for t, taps in [typo(rng, w)]
        )
    )
    words = sorted({w for _, w in pool if len(w) >= 5})
    pairs = [(m, w) for w in rng.sample(words, 1500) for m in [spelling(rng, w)] if m]
    (out / "misspellings.tsv").write_text(
        "".join(
            row("", m, w, [tap(rng, ch, True) for ch in m]) + "\n" for m, w in pairs
        )
    )
    texts = [
        t
        for t in dict.fromkeys(read("nus-sms"))
        if 3 <= len(t.split()) <= 30 and any(len(w) >= 3 for _, w in targets(t, 1))
    ]
    rng.shuffle(texts)
    (out / "next-texts.tsv").write_text(
        "".join(row(c, "", w) + "\n" for t in texts[:200] for c, w in targets(t, 1))
    )
    (out / "text-typos.tsv").write_text(
        "".join(
            row(c, typed, w, taps) + "\n"
            for t in texts[200:]
            for c, w in [rng.choice([x for x in targets(t, 3)])]
            for typed, taps in [typo(rng, w)]
        )
    )
    for f in sorted(out.glob("*.tsv")):
        print(f"{f.name}: {len(f.read_text().splitlines())} rows")


if __name__ == "__main__":
    main(sys.argv[1])
