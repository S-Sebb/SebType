"""Makes the slip set (#478): common phrases typed with one slip each, by kind, to check that 中文's typo
correction puts the intended phrase first or on page 1.

  python3 -I make-slips.py SETS_DIR   # writes slips.tsv (keys, phrase, kind) into SETS_DIR

Each phrase gets one slip of each kind, at a seeded random letter: drop (a letter missing), double (a
letter typed twice), swap (two letters swapped) and near (a neighbouring key on a PC's ANSI keyboard,
keys within 1.25 key pitches, as typo-pc). The phrases are everyday words, the 越…越… and 一…就… patterns and
common idioms, plus the slips users reported (REPORTED).
"""

import random
import sys

PHRASES = """
越来越小 yue lai yue xiao
越来越好 yue lai yue hao
越来越多 yue lai yue duo
越来越难 yue lai yue nan
越快越好 yue kuai yue hao
越早越好 yue zao yue hao
越想越气 yue xiang yue qi
一看就懂 yi kan jiu dong
一学就会 yi xue jiu hui
一说就明白 yi shuo jiu ming bai
一想就知道 yi xiang jiu zhi dao
又快又好 you kuai you hao
边走边说 bian zou bian shuo
一心一意 yi xin yi yi
乱七八糟 luan qi ba zao
莫名其妙 mo ming qi miao
自言自语 zi yan zi yu
不知不觉 bu zhi bu jue
实事求是 shi shi qiu shi
半途而废 ban tu er fei
胡说八道 hu shuo ba dao
理所当然 li suo dang ran
一模一样 yi mu yi yang
想方设法 xiang fang she fa
迫不及待 po bu ji dai
小心翼翼 xiao xin yi yi
无可奈何 wu ke nai he
心不在焉 xin bu zai yan
我们一起去 wo men yi qi qu
你在干什么 ni zai gan shen me
没关系 mei guan xi
怎么办 zen me ban
我觉得 wo jue de
明天见 ming tian jian
不好意思 bu hao yi si
我知道了 wo zhi dao le
现在几点了 xian zai ji dian le
已经 yi jing
喜欢 xi huan
学校 xue xiao
朋友 peng you
时间 shi jian
问题 wen ti
工作 gong zuo
应该 ying gai
准备 zhun bei
漂亮 piao liang
简单 jian dan
"""

REPORTED = [("yuelaiyuxiao", "越来越小", "reported")]  # #478

ROWS = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]


ANSI = {
    k: (i + (0, 0.25, 0.75)[r], r)
    for r, row in enumerate(ROWS)
    for i, k in enumerate(row)
}


def neighbours(k):
    x, y = ANSI[k]
    return [
        j
        for j, (a, b) in ANSI.items()
        if j != k and (a - x) ** 2 + (b - y) ** 2 <= 1.25**2
    ]


def slip(rng, keys, kind):
    i = rng.randrange(len(keys))
    if kind == "drop":
        return keys[:i] + keys[i + 1 :]
    if kind == "double":
        return keys[:i] + keys[i] + keys[i:]
    if kind == "near":
        return keys[:i] + rng.choice(neighbours(keys[i])) + keys[i + 1 :]
    j = rng.choice([p for p in range(len(keys) - 1) if keys[p] != keys[p + 1]])
    return keys[:j] + keys[j + 1] + keys[j] + keys[j + 2 :]


def main():
    rng = random.Random(478)
    out = list(REPORTED)
    for line in PHRASES.strip().split("\n"):
        text, *syllables = line.split()
        keys = "".join(syllables)
        for kind in ("drop", "double", "swap", "near"):
            out.append((slip(rng, keys, kind), text, kind))
    with open(f"{sys.argv[1]}/slips.tsv", "w", encoding="utf-8") as f:
        f.writelines("\t".join(item) + "\n" for item in out)


main()
