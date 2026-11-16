# Training data for SebType's Chinese model

Openly licensed text only. None of it is the user's words, userdb or other personal data. Every source was
downloaded at the revision below, and its licence was checked there (`fetch.sh` pins the revisions).

| Source | What the corpus takes | Licence | Revision |
|---|---|---|---|
| [Chinese Wikipedia](https://huggingface.co/datasets/wikimedia/wikipedia) (dump of 2023-11-01, `20231101.zh`) | article paragraphs, in simplified characters | CC BY-SA (3.0 on the dataset card; Wikipedia's text is CC BY-SA 4.0 and GFDL), by Wikipedia's contributors | `b04c8d1c` |
| [LCCC base](https://huggingface.co/datasets/silver/lccc) (Wang et al. 2020) | the turns of its train split's dialogues; its valid and test splits aren't read | MIT | `5bd582fa` |
| [OpenAssistant oasst2](https://huggingface.co/datasets/OpenAssistant/oasst2) (2023-11-05, all messages) | Chinese messages, both sides | Apache-2.0 | `179dd21f` |
| [Chinese Wikinews](https://dumps.wikimedia.org/zhwikinews/20261101/) (dump of 2026-11-01) | published articles' lead text, without the 600 newest (the harness's test and dev articles) | CC BY 2.5, by Wikinews's contributors | `zhwikinews-20261101-pages-articles.xml.bz2` |

Tools whose data shapes the training text, not part of it: [OpenCC](https://github.com/BYVoid/OpenCC)'s
traditional-to-simplified tables (Apache-2.0, through opencc-python-reimplemented), [pypinyin](https://github.com/mozillazg/python-pinyin)
(MIT) for the pinyin and [jieba](https://github.com/fxsjy/jieba) (MIT) for word boundaries.

**The harness's test sets stay out** (`corpus.py`):

- LCCC's test split (the chat sets) and valid split (the dev sets) aren't read;
- the 600 newest Wikinews articles (`android/test/chinese-lm/sets/wikinews-articles.tsv` and the dev sets'
  400) are left out by page id;
- any line from any source that shares 10 characters in a row with a test or dev item (its context and target)
  is dropped, and so is a line holding a whole item of 6 to 9 characters. `overlap.py` checks the corpus again
  afterwards: 0 lines, 0 of 5,054 items.

**The model's licence** is CC BY-SA 4.0, following docs/plans/android-own-keyboard.md's Decisions 6 for the
English model, because part of the data (Wikipedia) is share-alike. If the model file ever ships, NOTICE
credits every source above. The scripts in this folder stay MIT.
