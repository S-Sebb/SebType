# Chinese benchmark sets (#40)

Each line is `keys<TAB>expected`: what is typed and the text that should come first. 800 items per
set, drawn with seed 40; the pinyin comes from pypinyin. None of this text is in any dictionary tested.

| Set | What is typed |
|---|---|
| `*-sent` | Han clauses of 2–12 characters in full pinyin (`zhangdaobingchadehoujinertaidale` → 长岛冰茶的后劲儿太大了) |
| `*-abbr` | 2–4-character words as initials (`zd` → 知道), sampled by occurrence |
| `*-partial` | full pinyin except the last syllable's initial (`ranh` → 然后) |

Sources:

- `chat-*`: the test split of LCCC-base, Weibo-style dialogues ([thu-coai/lccc](https://huggingface.co/datasets/thu-coai/lccc),
  by thu-coai, MIT licence).
- `news-*`: the 250 newest articles of Chinese Wikinews, 2025 to May 2026, in the zh-cn variant
  ([zh.wikinews.org](https://zh.wikinews.org), [CC BY 2.5](https://creativecommons.org/licenses/by/2.5/)).
