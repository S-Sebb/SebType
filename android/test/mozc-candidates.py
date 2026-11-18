"""Types each romaji word of WORDS into Mozc loaded with the data set DICT (#335) and checks its candidates.

    python3 -I mozc-candidates.py MOZC_LIBRARY DICT WORDS          # check against WORDS
    python3 -I mozc-candidates.py MOZC_LIBRARY DICT WORDS --print  # print what DICT gives, in WORDS' format

MOZC_LIBRARY is SebType's Mozc with its C interface (libsebtype-mozc.so). WORDS has one line per word: the
romaji, then tab-separated the first suggestions shown after its last key and the first candidates of its
conversion with Space, each list joined by " | ". The check passes when DICT gives exactly those. Mozc's
minimal engine, which it falls back to when a data set doesn't load, gives no kanji at all.
"""

import importlib.util
import os
import sys
import tempfile

TOP = 10
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location(
    "perf_mozc", os.path.join(here, "../../pc/linux/perf-mozc.py")
)
perf = importlib.util.module_from_spec(spec)
spec.loader.exec_module(perf)


def candidates(out):  # the first TOP values of all_candidate_words
    words = [
        dict(perf.fields(c)).get(4, b"").decode()
        for n, c in perf.fields(out.get(14, b""))
        if n == 2
    ]
    return " | ".join(words[:TOP])


def main():
    library, data, words_file = sys.argv[1:4]
    sys.stdout.reconfigure(encoding="utf-8")
    with open(words_file, encoding="utf-8") as f:
        lines = [l.rstrip("\n").split("\t") for l in f if l.strip()]
    with tempfile.TemporaryDirectory() as profile:  # empty: nothing learned
        mozc = perf.Mozc(os.path.abspath(library), profile, os.path.abspath(data))
        session = mozc.call(perf.field(1, perf.CREATE_SESSION))[1]
        perf.send_key(mozc, session, special=perf.ON)
        bad = 0
        for line in lines:
            for c in line[0]:
                out = perf.send_key(mozc, session, char=c)
            got = [line[0], candidates(out)]
            got.append(candidates(perf.send_key(mozc, session, special=perf.SPACE)))
            mozc.call(
                perf.field(1, perf.SEND_COMMAND)
                + perf.field(2, session)
                + perf.field(4, perf.field(1, perf.REVERT))
            )
            if "--print" in sys.argv:
                print("\t".join(got))
            elif got != line:
                bad += 1
                print(f"want\t{chr(9).join(line)}\ngot\t{chr(9).join(got)}")
        mozc.close()
    if "--print" not in sys.argv:
        print(f"{len(lines) - bad}/{len(lines)} words give the same candidates")
        sys.exit(1 if bad else 0)


main()
