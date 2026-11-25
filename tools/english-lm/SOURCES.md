# Training data for SebType's English model

Openly licensed text only. None of it is the user's words, learned data or other personal data. Every source
was downloaded at the revision below, and its licence was checked there (`fetch.sh` pins the revisions).

| Source | What the corpus takes | Licence | Revision |
|---|---|---|---|
| [English Wikipedia](https://huggingface.co/datasets/wikimedia/wikipedia) (dump of 2023-11-01, `20231101.en`) | article paragraphs, no headings or lists | CC BY-SA (3.0 on the dataset card; Wikipedia's text is CC BY-SA 4.0 and GFDL), by Wikipedia's contributors | `b04c8d1c` |
| [Simple English Wikipedia](https://huggingface.co/datasets/wikimedia/wikipedia) (`20231101.simple`) | the same | the same | `b04c8d1c` |
| [OpenAssistant oasst2](https://huggingface.co/datasets/OpenAssistant/oasst2) (2023-11-05, all messages) | English messages, both sides, without oasst1's prompts | Apache-2.0 | `179dd21f` |
| [OpenAssistant oasst1](https://huggingface.co/datasets/OpenAssistant/oasst1) prompts (2023-04-12) | nothing: read only to leave these messages out (the harness's chat sentences come from them) | Apache-2.0 | `fdf72ae0` |
| [SODA](https://huggingface.co/datasets/allenai/soda) | the turns of its dialogues (written by GPT-3.5 from Atomic10x knowledge, as its paper says) | CC BY 4.0, Allen Institute for AI | `fdc848ab` |
| [databricks-dolly-15k](https://huggingface.co/datasets/databricks/databricks-dolly-15k) | instructions and responses | CC BY-SA 3.0, Databricks | `bdd27f4d` |
| [NUS SMS Corpus](https://scholarbank.nus.edu.sg/handle/10635/137343) (2015-03-09 release, files from [its authors' repository](https://github.com/kite1988/nus-sms-corpus)) | real text messages, without those with Singlish particles or with a word that is neither a lowercase dictionary word nor used by 5 senders (first names): 21,817 lines from its 55,835 messages | CC BY 4.0, National University of Singapore (Tao Chen, Min-Yen Kan) | `bf0a3651` |
| [Blended Skill Talk](https://github.com/facebookresearch/ParlAI/tree/main/parlai/tasks/blended_skill_talk) (Hugging Face's copy, [ParlAI/blended_skill_talk](https://huggingface.co/datasets/ParlAI/blended_skill_talk)) | the crowd workers' own unguided turns (`free_messages`), not the seed turns, nor the guided ones, which can be a suggestion copied from another dataset | CC BY 4.0, Meta (Facebook AI Research); ParlAI's `LICENSE_DOCUMENTATION` at `a29567f7` | `d7b00932` |
| [Topical-Chat](https://github.com/alexa/Topical-Chat) | the turns of its conversations, all splits | CDLA-Sharing 1.0, Amazon (`DATALICENSE`; §3.5 puts no conditions on a trained model) | `7c939229` |
| [Tatoeba](https://tatoeba.org/en/downloads) (English sentences, export of 2026-11-14, kept in the cache by its sha256, as Tatoeba keeps no old exports) | sentences without names: a word Tatoeba capitalises mid-sentence more often than not drops its sentence (Tom, Mary, places, languages) | CC BY 2.0 FR (some sentences CC0), by Tatoeba's contributors | `3b5b3ecf` (sha256) |
| [English Wikinews](https://dumps.wikimedia.org/enwikinews/20261101/) (dump of 2026-11-01) | articles, without the 200 the harness's news sentences come from | CC BY 2.5, by Wikinews's contributors | `enwikinews-20261101-pages-articles.xml.bz2` |

**The harness's test sets stay out** (`corpus.py`):

- oasst1's prompts are left out of oasst2 by id and by text;
- the 200 Wikinews articles in `android/test/english/sets/wikinews-articles.tsv` are left out by title;
- the 1,400 NUS SMS messages in `android/test/english/sets/nus-sms-held-out.txt` are left out by id, and so is
  every message with the same words;
- any line from any source that shares 8 words in a row with a harness item is dropped (a whole item of 5 to 7
  words, too). `overlap.py` checks the corpus again afterwards.

Wikipedia's list of common misspellings, which the harness's misspellings set comes from, isn't used. The
spelling mistakes in training are made by rule (`noise.py`).

**The model's licence** is CC BY-SA 4.0 (the user, 2026-11-15; docs/plans/android-own-keyboard.md, Decisions 6),
because part of the data is share-alike. When the model file ships, NOTICE credits every source it was trained on. The
scripts in this folder stay MIT.
