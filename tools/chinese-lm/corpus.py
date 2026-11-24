"""Builds the training corpus from the downloaded sources (SOURCES.md), one text segment per line.

  corpus.py RUN_DIR

Reads RUN_DIR/data/src (fetch.sh) and writes RUN_DIR/data/corpus/SOURCE.txt and SOURCE.dev.txt: the segments
of the documents common.split() puts in train and in dev (an article, a dialogue, a meeting, a message tree;
the dev loss reads them). The test documents aren't read. A segment is a paragraph or a chat turn, in
simplified characters (common.clean), each once: a segment seen before in any source, or in a dev or test
document, isn't written again (#557: through duplicates, dev text was training text).

The harness's text stays out (android/test/chinese-lm):
- its sets come from the test and dev documents, and from the 600 newest Wikinews articles (the test and dev
  sets' 200 and 400), which are dev or not read;
- any training line, from any source, that shares 10 characters in a row with a test or dev item (its context
  and target), or holds a whole item of 6 to 9 characters, is dropped. overlap.py checks the corpus again.
"""

import multiprocessing as mp
import sys
from pathlib import Path

sys.path.insert(
    0, str(Path(__file__).resolve().parent)
)  # python -I leaves the script's folder out
import common
import pyarrow.parquet as pq

SETS = Path(__file__).resolve().parents[2] / "android/test/chinese-lm/sets"
N = 10
# yanglab16 is shared and its disk is the NAS: few workers keep within a small share of its CPUs and I/O.
WORKERS = 12

grams = whole = None


def items(run):
    """The test and dev items' text: context and target, as typed into one field."""
    out = []
    for d in (SETS, Path(run) / "dev"):
        for f in sorted(d.glob("*.tsv")):
            if "wikinews-articles" in f.name:
                continue
            for line in f.read_text(encoding="utf-8").splitlines():
                ctx, _, target = line.split("\t")[:3]
                out.append(ctx + target)
    return out


def init(run):
    global grams, whole
    texts = items(run)
    grams = {t[i : i + N] for t in texts for i in range(len(t) - N + 1)}
    whole = {t for t in texts if 6 <= len(t) < N}


def leaks(s):
    return any(
        s[i : i + n] in (grams if n == N else whole)
        for n in range(6, N + 1)
        for i in range(len(s) - n + 1)
    )


def segments(doc):
    """A document's (split, its texts) as its kept segments: train's without the harness's items."""
    split, texts, min_len = doc
    out = []
    for t in texts:
        t = common.clean(t)
        if t and len(t) >= min_len and (split != "train" or not leaks(t)):
            out.append(t)
    return split, out


def wiki_part(part):
    path, group = part
    t = pq.ParquetFile(path).read_row_group(group, columns=["id", "text"])
    return [
        segments((common.split("wikipedia", i), text.split("\n"), 10))
        for i, text in zip(t.column(0).to_pylist(), t.column(1).to_pylist())
    ]


class Writer:
    """Writes each source's train and dev segments, each segment once over all of them, none that a dev or
    test document holds (HELD) in training."""

    def __init__(self, corpus, held):
        self.corpus, self.held, self.seen = corpus, held, set()

    def write(self, name, docs):
        with (
            open(self.corpus / f"{name}.txt", "w", encoding="utf-8") as t,
            open(self.corpus / f"{name}.dev.txt", "w", encoding="utf-8") as d,
        ):
            n = {"train": 0, "dev": 0, "dup": 0}
            for split, segs in docs:
                if split == "test":
                    continue
                for s in segs:
                    h = hash(s)
                    if h in self.seen or (split == "train" and h in self.held):
                        n["dup"] += 1
                        continue
                    self.seen.add(h)
                    (t if split == "train" else d).write(s + "\n")
                    n[split] += 1
        print(
            f"{name}: {n['train']} train lines, {n['dev']} dev lines, {n['dup']} repeated",
            flush=True,
        )


def main(run):
    run = Path(run)
    src, corpus = run / "data/src", run / "data/corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    news = common.news_split(src)
    assert len(news["test"]) == 200 and len(news["dev"]) == 400
    with mp.Pool(WORKERS, init, (run,)) as pool:
        docs = {
            "wikinews": [(s, ps, 4) for s, arts in news.items() for _, _, ps in arts]
        }
        for source, s, _, turns in common.chat(src):
            docs.setdefault(source, []).append((s, turns, 4))
        docs = {name: pool.map(segments, d, chunksize=64) for name, d in docs.items()}
        held = {
            hash(t)
            for d in docs.values()
            for s, segs in d
            if s != "train"
            for t in segs
        }
        w = Writer(corpus, held)
        for name in ["wikinews", *common.CHAT]:
            w.write(name, docs[name])
        parts = [
            (f, g)
            for f in sorted((src / "wikipedia/20231101.zh").glob("*.parquet"))
            for g in range(pq.ParquetFile(f).num_row_groups)
        ]
        w.write("wikipedia", (d for part in pool.imap(wiki_part, parts) for d in part))


if __name__ == "__main__":
    main(sys.argv[1])
