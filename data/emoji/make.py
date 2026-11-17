#!/usr/bin/env python3
"""Writes the new keyboard's emoji list from Unicode's emoji-test.txt and CLDR's annotations (build.sh).

    make.py OUTPUT EMOJI_TEST ANN_EN DERIVED_EN ANN_ZH DERIVED_ZH ANN_JA DERIVED_JA

Output, UTF-8 text: a line "# <group>" starts each of the picker's groups (emoji-test's, without its
"Component" group of bare skin tones and hair parts); every other line is one emoji, tab-separated: the
emoji, its name in English, 中文 and 日本語 (CLDR's text-to-speech name), then, for emoji that take a skin
tone, its five variants (light to dark) separated by spaces. Only fully-qualified emoji are listed; a
variant with mixed tones (two people, two tones) is left out, so a tone applies to the whole emoji.
"""

import json
import sys

out, test, *ann = sys.argv[1:]
TONES = {0x1F3FB, 0x1F3FC, 0x1F3FD, 0x1F3FE, 0x1F3FF}


def names(annotations, derived):
    n = {}
    for f in (
        derived,
        annotations,
    ):  # an emoji's own annotation wins over a derived one
        with open(f, encoding="utf-8") as fp:
            d = json.load(fp)
        key = "annotationsDerived" if "annotationsDerived" in d else "annotations"
        for k, v in d[key]["annotations"].items():
            if "tts" in v:
                n[k.replace("️", "")] = v["tts"][0]
    return n


langs = [names(ann[i], ann[i + 1]) for i in range(0, 6, 2)]
groups = []  # (group, [(emoji, english name, [variants])])
base = None
with open(test, encoding="utf-8") as f:
    for line in f:
        if line.startswith("# group: "):
            groups.append((line[9:].strip(), []))
            continue
        if not line.strip() or line.startswith("#") or "; fully-qualified" not in line:
            continue
        cps = [int(c, 16) for c in line.split(";")[0].split()]
        emoji = "".join(map(chr, cps))
        english = line.split("#", 1)[1].split(" ", 3)[3].strip()
        tones = [c for c in cps if c in TONES]
        if tones:
            plain = [c for c in cps if c not in TONES]
            if base and [c for c in map(ord, base[0]) if c != 0xFE0F] == [
                c for c in plain if c != 0xFE0F
            ]:
                if len(set(tones)) == 1:
                    base[2].append(emoji)
            continue
        base = (emoji, english, [])
        groups[-1][1].append(base)

lines = []
for group, emoji in groups:
    if group == "Component":
        continue
    lines.append(f"# {group}")
    for e, english, variants in emoji:
        key = e.replace("️", "")
        row = [e, english, *(n.get(key, english) for n in langs[1:])]
        row[1] = langs[0].get(key, english)
        if len(variants) == 5:
            row.append(" ".join(variants))
        lines.append("\t".join(row))
with open(out, "w", encoding="utf-8") as f:
    f.write("\n".join(lines) + "\n")
