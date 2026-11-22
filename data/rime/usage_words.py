"""Re-orders 白霜 core's words by how much text uses them and adds the spellings it leaves out (#482), the
latter as rime_ice's dictionary sebtype_usage.

  python3 -I usage_words.py SHARED ESSAY TSPHRASES TSCHARACTERS JIEBA_DICT

白霜 core's word list is rime-ice's, which keeps one spelling of many variant pairs, often the dictionary's
preferred one (硫黄, 丫环, 钩心斗角, 黏土), and re-counts only those words. So the spelling people type (硫磺,
丫鬟, 勾心斗角, 粘土) isn't in it at all, and nothing later (the grammar, SebType's model, learning) can put
it first. A word comes back when two independent counts agree that it beats core's first word for the
same pinyin: 白霜's own corpus counts (essay.txt, traditional characters, read through OpenCC's t2s
tables), by a fifth, and jieba's mainland word frequencies (dict.txt, MIT). It must differ from a core
word with that pinyin in one character, read with a reading 8105 gives it, and that first word must be a
real word (in jieba too).
Its weight is the first word's scaled by their essay counts, so it comes just above it.
Before that, core's words that share a pinyin are re-ordered by the same two counts and 白霜's own weight
(see "Re-weighting" below): core's order puts a rarer word first far more often than it leaves a
spelling out. Words typed alone come first 87.1 % of the time instead of 84.6 % (6,165 wordfreq words),
and sentences don't move.
"""

import collections
import math
import sys

shared, essay_path, ts_phrases, ts_chars, jieba_path = sys.argv[1:]
CORE = ["8105", "41448", "base", "ext", "others"]
MIN_READING = 0.002  # of the character's main reading in 8105: 粘 nián is 0.3 % of zhān
MIN_JIEBA = 3  # jieba's floor: the outranked word is a word
FROST = 2  # 白霜's own weight counts twice: chat text, which jieba barely has, stays in 白霜's order
MIN_USAGE = 4  # jieba's count: below, a placeholder (3 for 159 k words), not a count
MARGIN = 1.2  # essay count over the outranked word's: near ties (天心 852, 甜心 828) stay as they are


def table(p):
    with open(p, encoding="utf-8") as f:
        return dict(
            (k, v.split(" ")[0]) for k, v in (l.rstrip("\n").split("\t") for l in f)
        )


phrases, chars = table(ts_phrases), table(ts_chars)
longest = max(map(len, phrases))


def t2s(s):
    out, i = [], 0
    while i < len(s):
        for n in range(min(longest, len(s) - i), 1, -1):
            if s[i : i + n] in phrases:
                out.append(phrases[s[i : i + n]])
                i += n
                break
        else:
            out.append(chars.get(s[i], s[i]))
            i += 1
    return "".join(out)


essay = collections.Counter()
with open(essay_path, encoding="utf-8") as f:
    for line in f:
        w, c = line.rstrip("\n").split("\t")
        essay[t2s(w)] += int(c)
with open(jieba_path, encoding="utf-8") as f:
    jieba = {w: int(c) for w, c, *_ in (l.split(" ") for l in f)}

words = collections.defaultdict(dict)  # word -> code -> weight
readings = collections.defaultdict(dict)  # character -> reading -> weight
for name in CORE:
    with open(f"{shared}/cn_dicts/{name}.dict.yaml", encoding="utf-8") as f:
        body = f.read().partition("\n...\n")[2]
    for line in body.split("\n"):
        x = line.split("\t")
        if len(x) < 2 or line.startswith("#"):
            continue
        weight = int(x[2]) if len(x) > 2 and x[2].isdigit() else 0
        words[x[0]][x[1]] = max(words[x[0]].get(x[1], 0), weight)
        if len(x[0]) == 1:
            readings[x[0]][x[1]] = max(readings[x[0]].get(x[1], 0), weight)

# Re-weighting: within each pinyin and length, core's words that both counts know take core's weights in
# the order of their usage, the product of their essay count, their jieba count and their 白霜 weight
# squared; a word read several ways counts for each reading by its share of the word's weight. The
# weights themselves stay, so Rime's sentences, which compare weights across pinyin and lengths, keep
# their scale.
groups = collections.defaultdict(list)  # (code, length) -> [(weight, usage, word)]
for w, codes in words.items():
    if len(w) < 2 or not essay.get(w) or jieba.get(w, 0) < MIN_USAGE:
        continue
    total = sum(codes.values())
    usage = math.log(essay[w]) + math.log(jieba[w])
    for code, weight in codes.items():
        share = weight / total if total else 1 / len(codes)
        score = usage + 2 * math.log(share) + FROST * math.log(weight + 1)
        groups[(code, len(w))].append((weight, score, w))
moved = 0
for (code, _), g in groups.items():
    if len(g) < 2:
        continue
    for weight, (_, _, w) in zip(
        sorted((x[0] for x in g), reverse=True), sorted(g, key=lambda x: -x[1])
    ):
        moved += words[w][code] != weight
        words[w][code] = weight
for name in CORE:
    p = f"{shared}/cn_dicts/{name}.dict.yaml"
    with open(p, encoding="utf-8") as f:
        head, sep, body = f.read().partition("\n...\n")
    lines = body.split("\n")
    for i, line in enumerate(lines):
        x = line.split("\t")
        if len(x) > 2 and len(x[0]) > 1 and not line.startswith("#") and x[2].isdigit():
            x[2] = str(words[x[0]][x[1]])
            lines[i] = "\t".join(x)
    with open(p, "w", encoding="utf-8") as f:
        f.write(head + sep + "\n".join(lines))
print(f"rime-data: {moved} weights re-ordered by usage", file=sys.stderr)

first = {}  # (code, length) -> (weight, word): what core puts first
siblings = collections.defaultdict(list)  # (before, after) -> [(word, position)]
for w, codes in words.items():
    if len(w) < 2:
        continue
    for code, weight in codes.items():
        k = (code, len(w))
        first[k] = max(first.get(k, (-1, "")), (weight, w))
    for i in range(len(w)):
        siblings[(w[:i], w[i + 1 :])].append((w, i))

added = {}
for w, count in essay.items():
    if w in words or len(w) < 2 or not jieba.get(w):
        continue
    for i in range(len(w)):
        for s, j in siblings.get((w[:i], w[i + 1 :]), ()):
            for code in words[s] if j == i else ():
                syllables = code.split(" ")
                r = readings.get(w[i], {})
                if (
                    (w, code) in added
                    or len(syllables) != len(w)
                    or r.get(syllables[i], -1)
                    < MIN_READING * max(r.values(), default=0)
                ):
                    continue
                weight, top = first[(code, len(w))]
                if (
                    jieba.get(top, 0) >= MIN_JIEBA
                    and count > MARGIN * essay.get(top, 0) > 0
                    and jieba[w] > jieba[top]
                ):
                    added[(w, code)] = max(1, round(weight * count / essay[top]))

with open(f"{shared}/cn_dicts/sebtype_usage.dict.yaml", "w", encoding="utf-8") as f:
    f.write(
        "# SebType (#482): spellings mainland text uses that 白霜 core leaves out (data/rime/usage_words.py)\n"
        '---\nname: sebtype_usage\nversion: "1"\nsort: by_weight\n...\n'
    )
    f.writelines(
        f"{w}\t{code}\t{weight}\n" for (w, code), weight in sorted(added.items())
    )
print(f"rime-data: {len(added)} usage spellings added", file=sys.stderr)
