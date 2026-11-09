"""Builds SebType's English main dictionary from FUTO's, wordfreq and SCOWL (configuration chosen in #47).

  make_dict.py FUTO_MAIN_EN_DICT WORDFREQ_LARGE_EN_MSGPACK_GZ SCOWL_HUNSPELL_DIR OUT_DICT OUT_COMBINED_GZ

- Words: all of FUTO's, plus wordfreq's frequent words (top 200 k) that FUTO lacks and that SCOWL's
  en_US-large spell checker accepts, as written, capitalised, or in SCOWL's own mixed case (GitHub).
  All-caps forms are left out, as FUTO removed acronyms on purpose.
- Weights: wordfreq's, mapped onto FUTO's 0-255 scale by rank over the words both lists share.
  FUTO words that wordfreq lacks keep FUTO's weight; FUTO's typo entries (not_a_word, e.g. "wierd"
  -> "weird") and shortcuts are kept as they are.
"""

import bisect
import gzip
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(
    0, os.path.dirname(os.path.abspath(__file__))
)  # run with python3 -I, which drops it
import v202

WORD_RE = re.compile(
    r"[A-Za-z]+(?:'[A-Za-z]+)?"
)  # plain words: letters with at most one apostrophe
MULTI_DIGIT_RE = re.compile(r"\d[\d.,]+")  # numbers, which top_n_list() leaves out
CANDIDATES = 200_000  # wordfreq ranks considered for new words
# New two-letter words are mostly abbreviations and pieces of words (th, st, ll) that would stop
# autocorrect from fixing them; "ai" is the modern word among them.
SHORT_WORDS = {"ai"}
FRAGMENTS = {"n't"}  # what wordfreq's tokenizer leaves of contractions
ATTRS = {
    "date": "1762646400",
    "dictionary": "main:en",
    "locale": "en",
    "version": "54",
    "description": "English (FUTO words, wordfreq weights, SCOWL-checked modern words)",
}


def msgpack(data, pos=0):
    """Minimal msgpack reader for wordfreq's cBpack files (arrays, maps, strings, small ints)."""
    b = data[pos]
    pos += 1
    if b <= 0x7F:
        return b, pos
    if 0xA0 <= b <= 0xBF or b in (0xD9, 0xDA, 0xDB):
        n, pos = (
            (b & 0x1F, pos)
            if b <= 0xBF
            else (
                int.from_bytes(data[pos : pos + (1, 2, 4)[b - 0xD9]], "big"),
                pos + (1, 2, 4)[b - 0xD9],
            )
        )
        return data[pos : pos + n].decode("utf-8"), pos + n
    if 0x90 <= b <= 0x9F or b in (0xDC, 0xDD):
        n, pos = (
            (b & 0x0F, pos)
            if b <= 0x9F
            else (
                int.from_bytes(data[pos : pos + (2, 4)[b - 0xDC]], "big"),
                pos + (2, 4)[b - 0xDC],
            )
        )
        out = []
        for _ in range(n):
            v, pos = msgpack(data, pos)
            out.append(v)
        return out, pos
    if 0x80 <= b <= 0x8F:
        out = {}
        for _ in range(b & 0x0F):
            k, pos = msgpack(data, pos)
            out[k], pos = msgpack(data, pos)
        return out, pos
    raise ValueError(f"unsupported msgpack type 0x{b:02x}")


def wordfreq_large_en(path):
    """{word: Zipf frequency} in wordfreq's order: top_n_list("en", wordlist="large") with zipf_frequency()."""
    header, *buckets = msgpack(gzip.decompress(Path(path).read_bytes()))[0]
    assert header == {"format": "cB", "version": 1}, header
    return {
        w: round(9 - i / 100, 2)
        for i, bucket in enumerate(buckets)
        for w in bucket
        if not MULTI_DIGIT_RE.match(w)
    }


def rescale(src, ref):
    """Maps src scores onto ref's scale by rank (quantile mapping over shared words)."""
    shared = sorted(set(src) & set(ref))
    xs = sorted(src[w] for w in shared)
    ys = sorted(ref[w] for w in shared)
    return {w: ys[min(len(ys) - 1, bisect.bisect_left(xs, s))] for w, s in src.items()}


def hunspell(args, words, hunspell_dir):
    return subprocess.run(
        ["hunspell", "-d", f"{hunspell_dir}/en_US-large", *args],
        input="\n".join(words),
        capture_output=True,
        text=True,
        check=True,
    ).stdout


def scowl_spellings(words, hunspell_dir):
    """{word: (SCOWL's spelling of it, its SCOWL stems)} for each lowercase word en_US-large accepts."""
    dic = (
        Path(f"{hunspell_dir}/en_US-large.dic")
        .read_text(encoding="utf-8")
        .split("\n")[1:]
    )
    mixed = {}
    for line in dic:
        stem = line.split("/")[0]
        if stem not in (stem.lower(), stem.capitalize(), stem.upper()):
            mixed.setdefault(stem.lower(), stem)
    forms = [[w, w.capitalize(), *([mixed[w]] if w in mixed else [])] for w in words]
    good = set(
        hunspell(["-G"], sorted({f for fs in forms for f in fs}), hunspell_dir).split()
    )
    spelling = {
        fs[0]: next(f for f in fs if f in good)
        for fs in forms
        if any(f in good for f in fs)
    }
    stems = {}
    for line in hunspell(["-s"], list(spelling.values()), hunspell_dir).splitlines():
        if line.strip():
            form, *stem = line.split()
            stems.setdefault(form, set()).update(stem or [form])
    return {w: (s, stems.get(s, {s})) for w, s in spelling.items()}


def main(futo_dict, wordfreq_path, hunspell_dir, out_dict, out_combined):
    _, futo = v202.decode(Path(futo_dict).read_bytes())
    # FUTO's real words on one lowercase scale, as the #40 benchmark compares them.
    ref = {}
    for w, (f, not_a_word, offensive, _) in futo.items():
        if not not_a_word and not offensive:
            ref[w.lower()] = max(ref.get(w.lower(), 0), f)
    all_wf = wordfreq_large_en(wordfreq_path)
    wf = {w: z for w, z in all_wf.items() if WORD_RE.fullmatch(w)}
    weight = rescale(wf, ref)

    # Case variants share one wordfreq count (us/US): only FUTO's most frequent variant takes it.
    words = dict(futo)
    top = {}
    for w, (f, not_a_word, _, _) in futo.items():
        if (
            not not_a_word
            and w.lower() in weight
            and f >= futo.get(top.get(w.lower()), (-1,))[0]
        ):
            top[w.lower()] = w
    for k, w in top.items():
        words[w] = (weight[k], *futo[w][1:])

    known = {w.lower() for w in futo}
    # A contraction typed without its apostrophe ("ive") must stay a typo that autocorrect fixes.
    contractions = {
        w.lower().replace("'", "")
        for w in futo
        if "'" in w and not w.lower().endswith("'s")
    }
    candidates = [
        w
        for w in list(all_wf)[:CANDIDATES]
        if w in wf
        and w not in known
        and w not in contractions
        and (len(w) > 2 or w in SHORT_WORDS)
        and w not in FRAGMENTS
    ]
    # Offensive by SCOWL (NOSUGGEST stems), by FUTO (same stem flagged) or by our own list.
    nosuggest = {
        l.split("/")[0]
        for l in Path(f"{hunspell_dir}/en_US-large.dic")
        .read_text(encoding="utf-8")
        .splitlines()
        if "/" in l and "!" in l.split("/")[1]
    }
    offensive = {w.lower() for w, v in futo.items() if v[2]} | set(
        (Path(__file__).resolve().parent / "offensive.txt").read_text().split()
    )
    added = scowl_spellings(candidates, hunspell_dir)
    for w, (spelling, stems) in added.items():
        flagged = bool(stems & nosuggest) or any(
            x.lower() in offensive for x in stems | {spelling}
        )
        words[spelling] = (weight[w], False, flagged, [])
    print(
        f"FUTO words {len(futo)}, reweighted {sum(words[w] != futo[w] for w in futo)}, added {len(added)} "
        f"({sum(words[s][2] for s, _ in added.values())} marked offensive), total {len(words)}",
        file=sys.stderr,
    )

    data = v202.encode(ATTRS, words)
    Path(out_dict).write_bytes(data)
    with gzip.open(out_combined, "wt", encoding="utf-8") as out:
        out.write(",".join(f"{k}={v}" for k, v in ATTRS.items()) + "\n")
        for w, (f, not_a_word, offensive, shortcuts) in sorted(
            words.items(), key=lambda x: (-x[1][0], x[0])
        ):
            out.write(
                f" word={w},f={f}"
                + (",not_a_word=true" if not_a_word else "")
                + (",possibly_offensive=true" if offensive else "")
                + "\n"
            )
            for target, sf in shortcuts:
                out.write(f"  shortcut={target},f={'whitelist' if sf == 15 else sf}\n")


if __name__ == "__main__":
    main(*sys.argv[1:])
