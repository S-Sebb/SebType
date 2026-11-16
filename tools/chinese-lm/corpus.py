"""Builds the training corpus from the downloaded sources (SOURCES.md), one text segment per line.

  corpus.py RUN_DIR

Reads RUN_DIR/data/src (fetch.sh) and writes RUN_DIR/data/corpus/SOURCE.txt plus a held-out SOURCE.dev.txt
(1 in 500 lines). A segment is a paragraph or a chat turn, in simplified characters (common.clean).

The harness's text stays out (android/test/chinese-lm):
- LCCC's test and validation dialogues aren't read: only its train split is;
- the 600 newest Wikinews articles (the test and dev sets' 200 and 400) are left out by page id;
- any line, from any source, that shares 10 characters in a row with a test or dev item (its context and
  target), or holds a whole item of 6 to 9 characters, is dropped. overlap.py checks the corpus again.
"""

import gzip
import json
import multiprocessing as mp
import random
import sys
from pathlib import Path

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


def keep(s):
    return s if s and len(s) >= 4 and not leaks(s) else None


def wiki_part(part):
    path, group = part
    out = []
    for text in (
        pq.ParquetFile(path)
        .read_row_group(group, columns=["text"])
        .column(0)
        .to_pylist()
    ):
        for p in text.split("\n"):
            p = common.clean(p)
            if p and len(p) >= 10 and keep(p):
                out.append(p)
    return out


def lccc_part(lines):
    out = []
    for line in lines:
        for t in json.loads(line):
            t = keep(common.clean(t))
            if t:
                out.append(t)
    return out


def chunks(it, n):
    buf = []
    for x in it:
        buf.append(x)
        if len(buf) == n:
            yield buf
            buf = []
    if buf:
        yield buf


def write(corpus, name, lines, rng):
    with (
        open(corpus / f"{name}.txt", "w", encoding="utf-8") as t,
        open(corpus / f"{name}.dev.txt", "w", encoding="utf-8") as d,
    ):
        n = 0
        for line in lines:
            (d if rng.random() < 1 / 500 else t).write(line + "\n")
            n += 1
    print(f"{name}: {n} lines", flush=True)


def main(run):
    run = Path(run)
    src, corpus = run / "data/src", run / "data/corpus"
    corpus.mkdir(parents=True, exist_ok=True)
    rng = random.Random(259)
    held = {
        int(l.split("\t")[0])
        for d in (SETS, run / "dev")
        for f in d.glob("*wikinews-articles.tsv")
        for l in f.read_text(encoding="utf-8").splitlines()
    }
    assert len(held) == 600, len(held)
    with mp.Pool(WORKERS, init, (run,)) as pool:
        news = []
        for pid, _, ps in common.wikinews(src / "zhwikinews-20261101.xml.bz2"):
            if pid not in held:
                news += [p for p in map(common.clean, ps) if p]
        write(
            corpus,
            "wikinews",
            [p for p in pool.map(keep, news, chunksize=500) if p],
            rng,
        )

        with gzip.open(
            src / "oasst2/2023-11-05_oasst2_all.messages.jsonl.gz",
            "rt",
            encoding="utf-8",
        ) as f:
            msgs = [m["text"] for m in map(json.loads, f) if m.get("lang") == "zh"]
        paras = [p for m in msgs for p in map(common.clean, m.split("\n")) if p]
        write(
            corpus,
            "oasst2",
            [p for p in pool.map(keep, paras, chunksize=500) if p],
            rng,
        )

        with gzip.open(
            src / "lccc/lccc_base_train.jsonl.gz", "rt", encoding="utf-8"
        ) as f:
            write(
                corpus,
                "lccc",
                (t for part in pool.imap(lccc_part, chunks(f, 20000)) for t in part),
                rng,
            )

        parts = [
            (f, g)
            for f in sorted((src / "wikipedia/20231101.zh").glob("*.parquet"))
            for g in range(pq.ParquetFile(f).num_row_groups)
        ]
        write(
            corpus,
            "wikipedia",
            (p for part in pool.imap(wiki_part, parts) for p in part),
            rng,
        )


if __name__ == "__main__":
    main(sys.argv[1])
