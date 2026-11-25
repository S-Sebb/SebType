# Training data for SebType's Chinese model

Openly licensed text only. None of it is the user's words, userdb or other personal data. Every source was
downloaded at the revision below, and its licence was checked there (`fetch.sh` pins the revisions). The
share is of the training characters (`pack.py`'s SHARE; Wikipedia and Wikinews make up the rest).

| Source | What the corpus takes | Share | Licence | Revision |
|---|---|---|---|---|
| [Chinese Wikipedia](https://huggingface.co/datasets/wikimedia/wikipedia) (dump of 2023-11-01, `20231101.zh`) | article paragraphs, in simplified characters | the base | CC BY-SA (3.0 on the dataset card; Wikipedia's text is CC BY-SA 4.0 and GFDL), by Wikipedia's contributors | `b04c8d1c` |
| [Chinese Wikinews](https://dumps.wikimedia.org/zhwikinews/20261101/) (dump of 2026-11-01) | published articles' lead text, without the 600 newest (the harness's test and dev articles) | the base | CC BY 2.5, by Wikinews's contributors | `zhwikinews-20261101-pages-articles.xml.bz2` |
| [AliMeeting](https://www.openslr.org/119/) (OpenSLR 119, Yu et al. 2022) and [AISHELL-4](https://www.openslr.org/111/) (OpenSLR 111, Fu et al. 2021) | the transcripts (TextGrids) of real, unscripted meetings, a turn per line, without AISHELL-4's `<sil>`, `<%>` and `&` marks; no audio is kept | 8 % | CC BY-SA 4.0, by Alibaba DAMO Academy and AISHELL | `Train_Ali_near`, `Eval_Ali`; `train_L`, `train_M`, `train_S`, `test` |
| [HundredCV-Chat](https://huggingface.co/datasets/Jax-dan/HundredCV-Chat) | generated (DeepSeek-V3) chats, without the speaker labels and the turns that open with a persona's name | 4 % | Apache-2.0 | `cece0fa1` |
| [Tatoeba](https://tatoeba.org/) (Mandarin sentences, export of 2026-11-24) | short everyday sentences, in simplified characters | 1.5 % | CC BY 2.0 FR, by Tatoeba's contributors | `cmn_sentences_detailed.tsv.bz2`, kept in the cache (Tatoeba keeps no old exports) |
| [KdConv](https://github.com/thu-coai/KdConv) (Zhou et al. 2020) | the short turns of its film, music and travel dialogues: no knowledge-card text, digits, addresses or phone numbers, at most 40 characters; for the harness's chat sets only (its pilot gained nothing, see below) | 0 % | Apache-2.0 | `653db764` |
| [OpenAssistant oasst2](https://huggingface.co/datasets/OpenAssistant/oasst2) (2023-11-05, all messages) | Chinese messages: the users', and the assistant's paragraphs that aren't list items or AI-isms (作为AI, 以下是) | 0.5 % | Apache-2.0 | `179dd21f` |

LCCC (r1's chat source) is gone since #557: its authors' terms are research-only (CDial-GPT's README:
仅限科研用途), whatever the MIT tag on its Hugging Face copy says, and it is scraped social-media text with no
personal-data filtering. CrossWOZ (templates), Common Voice's sentences (too few),
Johnson8187's dialogues (film subtitles under an MIT tag) and NaturalConv (no clear licence) were looked at and
left out (#557).

Each chat source was kept for what it adds to the chat dev sets: a pilot (1B tokens) without it against one
with every source, two seeds of which differ by up to 4 points on a set. Without the meetings the chat sets
lose 4.6 points on average, without HundredCV 4.5, Tatoeba 1.3, oasst2 1.6 (most on typos and slips), and
without KdConv nothing (0.2, as often up as down), so KdConv trains no more (#557).

Tools whose data shapes the training text, not part of it: [OpenCC](https://github.com/BYVoid/OpenCC)'s
traditional-to-simplified tables (Apache-2.0, through opencc-python-reimplemented), [pypinyin](https://github.com/mozillazg/python-pinyin)
(MIT) for the pinyin, corrected by the readings of [白霜](https://github.com/gaboolic/rime-frost)'s dictionary
(GPL-3.0; the words whose reading differs, read at `data/rime/build.sh`'s pin: the apps' own dictionary), and
[jieba](https://github.com/fxsjy/jieba) (MIT) for word boundaries.

**The harness's test and dev sets stay out** (`common.py`'s split(), `corpus.py`):

- whole documents are held out, by a hash of their id: a meeting, a dialogue, a message tree, a sentence or a
  Wikipedia article; the test documents aren't read, the dev documents only for the dev loss and dev sets;
- the 600 newest Wikinews articles (`android/test/chinese-lm/sets/wikinews-articles.tsv` and the dev sets'
  400) are left out by page id;
- a line is written once over all sources, and a training line that a test or dev document also holds is
  dropped;
- any training line that shares 10 characters in a row with a test or dev item (its context and target) is
  dropped, and so is a line holding a whole item of 6 to 9 characters. `overlap.py` checks the corpus again
  and fails on any.

**The model's licence** is CC BY-SA 4.0, following docs/plans/android-own-keyboard.md's Decisions 6 for the
English model, because part of the data (Wikipedia, the meetings) is share-alike. NOTICE credits every source
above. The scripts in this folder stay MIT.
