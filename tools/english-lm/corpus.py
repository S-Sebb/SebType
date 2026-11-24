"""Builds the training corpus from the downloaded sources (SOURCES.md), one text segment per line.

  corpus.py RUN_DIR

Reads RUN_DIR/data/src (fetch.sh) and writes RUN_DIR/data/corpus/SOURCE.txt plus a held-out SOURCE.dev.txt
(1 in 500 documents: an article, a conversation, a message, so no dev line has its neighbours in training). A
segment is a paragraph or a chat message line: the text one field of a keyboard holds.

Text is folded to ASCII (accents dropped, typographic quotes and dashes made plain, runs of spaces made one),
Markdown's emphasis and list markers are taken off (oasst2's answers have them), and lines with code, URLs,
other markup or other scripts are dropped. The English harness's test sentences stay out (android/test/english):
- oasst1's initial prompts, the harness's chat pool, are left out of oasst2 entirely;
- the 200 Wikinews articles the harness's news sentences come from are left out of the Wikinews dump;
- the NUS SMS messages the harness's texting sets come from are left out, with every message of the same words;
- any line, from any source, that shares 8 words in a row with a harness item is dropped (overlap.py checks).
"""

import bz2
import gzip
import json
import multiprocessing as mp
import random
import re
import sys
import unicodedata
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

import pyarrow.parquet as pq

ROOT = Path(__file__).resolve().parents[2]
HARNESS = ROOT / "android/test/english/sets"
FOLD = str.maketrans(
    {
        "‘": "'",
        "’": "'",
        "‚": "'",
        "“": '"',
        "”": '"',
        "„": '"',
        "–": "-",
        "—": "-",
        "…": "...",
        " ": " ",
        " ": " ",
        " ": " ",
        "ß": "ss",
        "æ": "ae",
        "Æ": "AE",
        "ø": "o",
        "Ø": "O",
        "đ": "d",
        "ł": "l",
        "Ł": "L",
        "ı": "i",
    }
)
# Markup, code and URLs; a line may start with a quote (dialogue), not with other punctuation (headings).
BAD = re.compile(r"https?:|www\.|[`{}<>|@#\\^~_*\[\]]|\.\w{2,4}/|\s{2,}|^[^\w\"']")
LIST_MARKER = re.compile(r"^(?:\d{1,2}[.)]|[-*\u2022]) +")
EMPHASIS = re.compile(r"\*\*?(?=\S)(.+?)(?<=\S)\*\*?")
WORDS = re.compile(r"[a-z0-9']+")
WORD = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")
SINGLISH = {"lah", "lor", "leh", "liao", "hor", "sia", "lei"}
# Share of each source's lines held out for the dev sets; NUS gives more, for dev_sets.py's texting sets.
DEV_SHARE = {"nus-sms": 0.05}
NGRAM = 8
# yanglab16 is shared and its disk is the NAS: few workers keep within a quarter of its memory and I/O.
WORKERS = 8


def ascii_line(s):
    s = unicodedata.normalize("NFKD", s.translate(FOLD))
    s = "".join(c for c in s if not unicodedata.combining(c)).strip()
    s = EMPHASIS.sub(r"\1", LIST_MARKER.sub("", re.sub(" {2,}", " ", s)))
    return s if s.isascii() and s.isprintable() else None


def keep(s, min_words=3):
    return (
        s
        and len(s.split()) >= min_words
        and len(s) <= 2000
        and not BAD.search(s)
        and sum(c.isalpha() for c in s) >= 0.6 * len(s)
    )


def ngrams(s, n=NGRAM):
    w = WORDS.findall(s.lower())
    return {" ".join(w[i : i + n]) for i in range(len(w) - n + 1)}


def harness_ngrams():
    """8-word n-grams of every harness item's context and word (rows shorter than 8 words: the whole row)."""
    grams = set()
    for f in HARNESS.glob("*.tsv"):
        if f.name == "wikinews-articles.tsv":
            continue
        for line in f.read_text().splitlines():
            ctx, _, target = line.split("\t")[:3]
            n = len(WORDS.findall(f"{ctx} {target}".lower()))
            if n >= 5:
                grams |= ngrams(f"{ctx} {target}", min(NGRAM, n))
    return grams


EXCLUDE = None  # the harness's n-grams, set in each worker


def init_worker():
    global EXCLUDE
    EXCLUDE = harness_ngrams()


def clean(texts, min_words=3, prose=False):
    """Each of TEXTS (a document: its lines one segment each) as its segments, folded to ASCII and filtered.
    PROSE drops headings (no final punctuation)."""
    out = []
    for text in texts:
        doc = []
        for line in text.split("\n"):
            s = ascii_line(line)
            if not keep(s, min_words) or (prose and s[-1] not in ".!?\"')"):
                continue
            w = WORDS.findall(s.lower())
            if any(
                " ".join(w[i : i + k]) in EXCLUDE
                for k in (5, 6, 7, 8)
                for i in range(len(w) - k + 1)
            ):
                continue
            doc.append(s)
        if doc:
            out.append(doc)
    return out


def wikipedia(path):
    return clean(
        pq.read_table(path, columns=["text"], use_threads=False)
        .column("text")
        .to_pylist(),
        min_words=4,
        prose=True,
    )


def soda(path):
    t = (
        pq.read_table(path, columns=["dialogue"], use_threads=False)
        .column("dialogue")
        .to_pylist()
    )
    return clean(("\n".join(d) for d in t), min_words=2)


def oasst(path, excluded_ids, excluded_texts):
    trees = {}
    for m in map(json.loads, gzip.open(path, "rt")):
        if (
            m.get("lang") == "en"
            and not m.get("deleted")
            and m["message_id"] not in excluded_ids
            and m["text"].strip() not in excluded_texts
        ):
            trees.setdefault(m["message_tree_id"], []).append(m["text"])
    return clean(("\n".join(t) for t in trees.values()), min_words=2)


def dolly(path):
    rows = [json.loads(l) for l in open(path)]
    return clean((f"{r['instruction']}\n{r['response']}" for r in rows), min_words=2)


# A NUS message the export cut at its first apostrophe starts with the contraction's tail: "m going", "ll be".
CUT_TAIL = re.compile(r"(?:m|ll|s|t|re|ve|d) ")


def nus_sms(path, excluded_ids):
    """The NUS SMS Corpus's messages. Its <#> and <EMAIL> placeholders fail BAD. Left out:
    - messages with Singlish particles: two thirds of NUS is from Singapore, and they would rank for everyone;
    - messages with a word that isn't a lowercase dictionary word and that fewer than 5 senders used: NUS
      didn't remove first names ("andreu", "sophie"), and this catches them, as the harness's sets do.
    """
    sys.path.insert(0, str(ROOT / "data/en-dict"))
    import v202

    lower = {
        w
        for w in v202.decode((ROOT / "data/en-dict/en_US.dict").read_bytes())[1]
        if w.islower()
    }
    msgs = [
        (
            m.get("id"),
            m.findtext("source/userProfile/userID"),
            m.findtext("text") or "",
        )
        for m in ET.parse(path).getroot().iter("message")
    ]
    words = lambda t: tuple(WORDS.findall(t.lower()))
    senders = {}
    for _, u, t in msgs:
        for w in words(t):
            senders.setdefault(w, set()).add(u)
    held_out = {words(t) for i, _, t in msgs if i in excluded_ids}
    return clean(
        (
            t
            for i, _, t in msgs
            if i not in excluded_ids
            and words(t) not in held_out
            and not SINGLISH & set(words(t))
            and all(w in lower or len(senders[w]) >= 5 for w in words(t))
            and not CUT_TAIL.match(t)
        ),
        min_words=2,
    )


def bst(path):
    """Blended Skill Talk's unguided crowd workers' turns. Its seed turns and suggestions come from other
    datasets (EmpatheticDialogues is non-commercial), and its guided worker's turns are often a suggestion
    taken as it was (1,929 of 38,151 an EmpatheticDialogues one, #556), so they stay out."""
    t = pq.read_table(path, columns=["free_messages"]).to_pylist()
    return clean(("\n".join(r["free_messages"]) for r in t), min_words=2)


def topical_chat(paths):
    return clean(
        (
            "\n".join(turn["message"] for turn in conv["content"])
            for p in paths
            for conv in json.load(open(p)).values()
        ),
        min_words=2,
    )


def tatoeba(path):
    """Tatoeba's English sentences without names. A few names (Tom, Mary, Sami, Ziri) are in a third of
    them, and would become the model's favourite next words. A word is taken as a name when Tatoeba writes it
    capitalised mid-sentence more often than in lowercase; that also drops places and languages.
    """
    sents = [l.rstrip("\n").split("\t")[2] for l in bz2.open(path, "rt")]
    upper, lower = Counter(), Counter()
    for s in sents:
        for w in WORD.findall(s)[1:]:
            (upper if w[0].isupper() else lower)[w.lower()] += 1
    names = {
        w
        for w, n in upper.items()
        if n > lower[w] and w not in ("i", "i'm", "i'd", "i'll", "i've")
    }
    return clean(
        (s for s in sents if not names & {w.lower() for w in WORD.findall(s)}),
        min_words=2,
    )


def wikinews(path, excluded_titles):
    import mwparserfromhell

    texts = []
    ns = "{http://www.mediawiki.org/xml/export-0.11/}"
    for _, el in ET.iterparse(bz2.open(path), events=("end",)):
        if el.tag != ns + "page":
            continue
        title, page_ns = el.findtext(ns + "title"), el.findtext(ns + "ns")
        text = el.findtext(f"{ns}revision/{ns}text") or ""
        if (
            page_ns == "0"
            and title not in excluded_titles
            and not text.lower().startswith("#redirect")
        ):
            # Templates, links and tables to plain text; the source and category lines go with the templates.
            texts.append(
                mwparserfromhell.parse(text).strip_code(normalize=True, collapse=True)
            )
        el.clear()
    return clean(texts, min_words=4, prose=True)


def write(out, name, parts):
    """Writes each part's lines as it finishes, without repeats; Wikipedia's whole text doesn't fit in memory."""
    rng, seen, n = random.Random(name), set(), 0
    with (
        open(out / f"{name}.txt", "w") as train,
        open(out / f"{name}.dev.txt", "w") as dev,
    ):
        for p in parts:
            for doc in p.get():
                f = dev if rng.random() < DEV_SHARE.get(name, 0.002) else train
                for s in doc:
                    if hash(s) not in seen:
                        seen.add(hash(s))
                        f.write(s + "\n")
                        n += 1
    print(f"{name}: {n:,} lines", flush=True)


def main(run):
    src, out = Path(run) / "data/src", Path(run) / "data/corpus"
    out.mkdir(parents=True, exist_ok=True)
    # oasst1's initial prompts (the harness's chat pool), left out of oasst2 by id and by text.
    prompts = [
        json.loads(l)
        for l in gzip.open(
            src / "oasst1/2023-04-12_oasst_prompts.messages.jsonl.gz", "rt"
        )
    ]
    ids, texts = (
        {m["message_id"] for m in prompts},
        {m["text"].strip() for m in prompts},
    )
    titles = {
        l.split("\t")[1]
        for l in (HARNESS / "wikinews-articles.tsv").read_text().splitlines()
    }
    sms_ids = set((HARNESS / "nus-sms-held-out.txt").read_text().split())

    with mp.Pool(WORKERS, initializer=init_worker) as pool:
        jobs = {
            "oasst2": [
                pool.apply_async(
                    oasst,
                    (
                        src / "oasst2/2023-11-05_oasst2_all.messages.jsonl.gz",
                        ids,
                        texts,
                    ),
                )
            ],
            "dolly": [
                pool.apply_async(dolly, (src / "dolly/databricks-dolly-15k.jsonl",))
            ],
            "wikinews": [
                pool.apply_async(
                    wikinews, (src / "enwikinews-20261101.xml.bz2", titles)
                )
            ],
            "nus-sms": [
                pool.apply_async(
                    nus_sms, (src / "nus-sms/smsCorpus_en_2015.03.09_all.xml", sms_ids)
                )
            ],
            "bst": [
                pool.apply_async(bst, (f,))
                for f in sorted((src / "bst/data").glob("*.parquet"))
            ],
            "topical-chat": [
                pool.apply_async(
                    topical_chat, (sorted((src / "topical-chat").glob("*.json")),)
                )
            ],
            "tatoeba": [
                pool.apply_async(tatoeba, (src / "tatoeba-eng_sentences.tsv.bz2",))
            ],
            "soda": [
                pool.apply_async(soda, (f,))
                for f in sorted((src / "soda").glob("*.parquet"))
            ],
            "simplewiki": [
                pool.apply_async(wikipedia, (f,))
                for f in sorted((src / "wikipedia/20231101.simple").glob("*.parquet"))
            ],
            "wikipedia": [
                pool.apply_async(wikipedia, (f,))
                for f in sorted((src / "wikipedia/20231101.en").glob("*.parquet"))
            ],
        }
        for name, parts in jobs.items():
            write(out, name, parts)


if __name__ == "__main__":
    main(sys.argv[1])
