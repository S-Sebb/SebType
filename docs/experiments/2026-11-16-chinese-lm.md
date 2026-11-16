# Experiment: a small Chinese model on top of Rime (#259, 2026-11-16)

Today's 中文 is Rime: rime-ice, 白霜's dictionary, the zh-moqi octagram grammar and SebType's typo Lua, the data
the apps ship. The question was whether a small Chinese transformer, trained from scratch on openly licensed
text, beats it at three things, at about the English model's size and speed (about 30 MB, p95 under 20 ms per
key): the first candidate, pinyin typo fixes, and the next word after a commit.

**Summary.** It does, clearly, but at full strength it costs more time per key than the target. The model is
17 MB (16.6M parameters, Q6_K), trained in 41 minutes on one H100. Two ways of using it were measured:

- **Re-ranking Rime's first 4 candidates** fits the budget: 10.6 / 16.4 ms per key at p50 / p95. It helps
  abbreviations (news: 23.2 → 32.8 % first) and the last syllable cut short (chat 52.5 → 59.5 %, news 56.8 →
  65.2 %), but not typos (14.5 → 18.5 %) or full sentences (unchanged). Rime seldom offers the right text for
  those, so there is nothing to promote.
- **Adding the model's own candidates** (a beam of 2 from the letters) wins everywhere. Typos are fixed at
  rank 1 for 53.1 % instead of 14.5 %, in the top 3 for 68.2 % instead of 18.9 %. Full-pinyin sentences are
  right for 70.6 / 71.9 % (chat / news) instead of 60.9 / 65.5 %. It costs 19.6 / 42 ms per key at p50 / p95.
- **Next words** with nothing typed: 32.5 % (chat) and 27.5 % (news) in the top 3, where Rime predicts nothing.
  7.2 / 11.8 ms per prediction.

Two runs gave the same quality numbers, and their per-key p50 differ by under 2 %. **Recommendation:** go on
with it, as its own step in core/ on the engine thread, not as a librime plugin ([below](#recommendation)).

## Results

`android/test/chinese-lm/run.sh` on yanglab16, run 1 with run 2's latency in brackets. All three columns run
the same Rime build and data. The model's columns use `rerank=4 rankWeight=1.5`, and the third column adds
`generate=2 generatedRank=2`, tuned on the dev sets ([how](#how-the-model-and-rime-combine)). Rates are
percentages of the set's items.

| Measure (set, items) | Today: Rime, rime-ice + 白霜 + octagram | Rime, re-ranked by SebType's Chinese model | … and the model's own candidates |
|---|---|---|---|
| Sentence right at rank 1, full pinyin (chat, 800 clauses) | 60.9 % | 60.9 % | 70.6 % |
| Words right in the first candidate (chat) | 85.2 % | 84.0 % | 88.9 % |
| Sentence right at rank 1, full pinyin (news, 800 clauses) | 65.5 % | 65.2 % | 71.9 % |
| Words right in the first candidate (news) | 87.3 % | 86.0 % | 90.4 % |
| Word first / in the top 3, abbreviated, zd → 知道 (chat, 400) | 23.0 / 35.0 % | 24.8 / 37.8 % | 30.2 / 57.0 % |
| Word first / in the top 3, abbreviated, zd → 知道 (news, 400) | 23.2 / 41.0 % | 32.8 / 46.8 % | 37.0 / 56.8 % |
| Word first / in the top 3, last syllable abbreviated, ranh → 然后 (chat, 400) | 52.5 / 70.0 % | 59.5 / 72.5 % | 58.8 / 82.5 % |
| Word first / in the top 3, last syllable abbreviated, ranh → 然后 (news, 400) | 56.8 / 75.8 % | 65.2 / 77.2 % | 66.2 / 86.8 % |
| Typo fixed: intended text first / in the top 3 (phone typos and confusions, 799) | 14.5 / 18.9 % | 18.5 / 19.1 % | 53.1 / 68.2 % |
| … first, zh/z, ch/c, sh/s, ng/n confused | 4.7 % | 4.7 % | 47.7 % |
| … first, a letter doubled | 1.8 % | 5.3 % | 64.9 % |
| … first, a letter left out | 10.6 % | 11.2 % | 46.8 % |
| … first, a neighbouring key | 25.7 % | 33.4 % | 58.8 % |
| … first, two letters swapped | 15.2 % | 15.2 % | 54.5 % |
| … first, two typos | 4.9 % | 11.0 % | 45.1 % |
| Next word in the top 3, nothing typed (chat, 1500) | 0.0 % | 32.5 % | 32.5 % |
| Next word in the top 3, nothing typed (news, 1000) | 0.0 % | 27.5 % | 27.5 % |
| Per key, ms p50 / p95 (run 2 in brackets) | 1.22 / 3.4 (1.23 / 3.47) | 10.58 / 16.4 (10.77 / 16.78) | 19.6 / 42.09 (19.72 / 39.82) |
| Per next-word prediction, ms p50 / p95 | 0.0 / 0.0 | 7.23 / 11.76 | 7.07 / 11.91 |
| Peak RSS of the process | 43 MB | 81 MB | 81 MB |

What the model fixes is mostly context. Of the 800 chat clauses, the third column gets 110 right that Rime gets
wrong, and 32 the other way round. Examples:

| Typed | Rime's first | With the model |
|---|---|---|
| najiuyizhizhuchixiaqu | 那就抑制住吃下去 | 那就一直主持下去 |
| buyaoxiawoa | 不要下我啊 | 不要吓我啊 |
| woyouzhegerongxingma | 我又这个荣幸吗 | 我有这个荣幸吗 |
| shiyuanxiaokaichechumenma | 是院校开车出门吗 | 是元宵开车出门吗 |

Typos gain the most because Rime's correction (rime-ice's and `sebtype_typo.lua`) covers few of them: 14.5 %
here, close to #46's 22 % for phone typos alone. The model was trained with the same kinds of typo in front of
the text, so it reads them from the letters and the sentence before them.

## The harness

`android/test/chinese-lm/` drives core/'s own Rime engine (`core/src/rime.cpp`, `makeRime` with the
`rime_ice` schema) key by key on the host, with the data zip `data/rime/build.sh` makes. It runs in the pinned
Fedora build container, with Fedora's librime 1.16 and its Lua and octagram plugins as on Linux. Each item
starts from a fresh copy of a deployed user folder, so nothing is learned between items. `bench.sh` runs the
three stacks over every set, 16 processes at a time, each on one thread. `score.py` scores them, and
`run.sh` runs everything twice from nobara-pc and checks that the runs agree.

The sets (`make_sets.py`, committed in `sets/` with their licences) come from text training never sees:

| Source | Licence | Sets |
|---|---|---|
| LCCC base's test split (chat) | MIT | chat items, and 500 of the typo items |
| the 200 newest published Chinese Wikinews articles in the 2026-11-01 dump (news) | CC BY 2.5 | news items, and 300 of the typo items |

The dev sets for tuning come the same way from LCCC's validation split and the 400 articles before those.

- **Item format.** Each item is the 64 characters of text before it, the letters typed and the text meant.
- **Pinyin.** pypinyin writes the pinyin: full; initials only for words of 2–4 characters; or full with the
  last syllable cut to its first letter.
- **Typos.** One per item, 10 % with two, as in #46's phone mix: a neighbouring key (by the phone's key grid
  and touch spread), a letter left out, doubled or swapped. A fifth of them confuse zh/z, ch/c, sh/s or ng/n.
- **Next words.** The next word is jieba's next word after the context. The context is read ahead, untimed,
  as the keyboard would when the cursor moves.
- **Per key.** The time from the key to the first page of candidates, model included.

Caveats:

- **pypinyin.** It writes the sets' pinyin and the model's training letters, so where it gets a heteronym
  wrong (长岛 as zhang dao), the model learned the same mistake and Rime didn't. The examples above are real
  pinyin, so this is a small part of the gain, but it is not measured.
- **One thread, on the host.** The latencies are yanglab16's EPYC on one thread, not the phone. The English
  model's host and phone numbers (docs/perf/2026-11-15-english.md) are the guide for how they carry over.
- **No learning.** Rime's user dictionary starts empty for every item, so neither stack learns the user's
  words. A real Rime would rank the user's own words higher, and the model would need to respect that.
- **Simplified characters only.** The model works in simplified characters. For 繁, OpenCC would convert its
  candidates after it, as rime-ice does for Rime's own.

## The model

`tools/chinese-lm/` (README, SOURCES.md):

- **Size.** A Llama-style transformer: 8 layers, width 384, 6 heads, feed-forward 1,024, 256 tokens of
  context, input and output embeddings shared. 16.6M parameters, 17 MB as GGUF Q6_K. llama.cpp runs it
  unchanged.
- **Vocabulary.** Characters: SentencePiece `char` over the corpus's 6,100 commonest characters, a–z, the
  special tokens and 256 byte pieces for anything else (6,382 in all). It needs no segmentation of the text
  before the cursor and no dictionary.
- **Corpus.** 2.7 GB of text, in simplified characters:

  | Source | Lines | Licence |
  |---|---|---|
  | Chinese Wikipedia | 10.7M paragraphs | CC BY-SA |
  | LCCC base, train split | 17.1M chat turns | MIT |
  | oasst2's Chinese messages | 25k | Apache-2.0 |
  | Chinese Wikinews, without the 600 held-out articles | 15k | CC BY 2.5 |

  `pack.py` weights them toward chat and news. No user text or userdb is used. `overlap.py` finds no corpus
  line sharing 10 characters with a test item, and no test item hit (0 of 5,054).
- **Pinyin examples in the text.** About once every 30 characters, before a span of up to 14 characters on
  jieba's word boundaries, the text holds the letters typed for it: `<T>letters<S>span<E>`. The letters are
  - its full pinyin (45 %);
  - full pinyin with a typo of the kinds above (25 %);
  - initials only (10 %);
  - the last syllable cut short (15 %);
  - some syllables abbreviated (5 %).

  The loss skips the letters, so the model learns to write the span from them and the text before.
- **Word ends.** An extra output, `<B>`, never an input, is trained to say where jieba ends a word. Next-word
  prediction uses it to know when a word is complete.
- **Training.** 3.9B tokens: three passes over the corpus, each with fresh pinyin examples. Learning rate
  2e-3, one H100, 41 minutes.

  | Final loss | Value |
  |---|---|
  | text | 2.79 |
  | span, given its letters | 0.48 |
  | word end | 0.18 |

One round was enough. The first plan was width 512 and 30M parameters, but on random weights that took about
20 ms per key at p50 without generation. The smaller model halved it before any training.

### How the model and Rime combine

At each key, `src/zh_lm.cpp` (the harness's loader, built like `engines/sebtype-lm`):

1. Reads Rime's first `rerank` candidates.
2. Scores each as log P(candidate, then `<E>` | context `<T>letters<S>`), with every candidate a branch of one
   batch, after a KV cache that keeps the context and the letters typed so far.
3. With `generate`, adds its own candidates: a beam search of that width from `<S>` to `<E>`, decoded one
   character at a time for all beams at once.
4. Ranks them all by the score minus `rankWeight · ln(1 + Rime's rank)`, where a candidate of the model's own
   counts as Rime's rank `generatedRank`. Rime's later candidates follow in Rime's order.

With nothing typed, `nextWords` follows the 8 likeliest first characters and keeps the 6 best prefixes per
length, up to 4 characters. A prefix stops being a word candidate once `<B>` says no word ends there. The search
stops when 3 words beat every live prefix.

`tools/chinese-lm/tune.py` chose the weights by mean top-1 over the 7 typed dev sets, on one dump scored at the
widest settings. Without the model's own candidates, 4 candidates get 43.4 % against 44.6 % for 8, at less
cost. With them, a beam of 2 got 52.4 % against 51.5 % for a beam of 4.

| Dev mean top-1 | Value |
|---|---|
| Rime's order | 39.8 % |
| re-ranked | 43.4 % |
| with the model's own candidates | 51.6 % |

## Size and speed

| | Rime alone | Re-ranked | With the model's own candidates |
|---|---|---|---|
| Files added | — | 17 MB model | 17 MB model |
| Peak RSS | 43 MB | 81 MB (+38) | 81 MB |
| Per key p50 / p95 | 1.2 / 3.4 ms | 10.6 / 16.4 ms | 19.6 / 42 ms |
| Next word p50 / p95 | — | 7.2 / 11.8 ms | 7.2 / 11.9 ms |

Most of the extra memory is llama.cpp's buffers. The KV cache holds 1,024 positions shared by up to 49 sequences,
more than these searches use, so a smaller one would save part of it. Of the time per key:

- **Scoring.** About 9 ms of the 10.6 ms p50 is scoring the 4 candidates: ~30 tokens in one batch.
- **Generation.** About 9 ms more at p50, and most of the p95, is the beam. It decodes one step per character,
  so long clauses cost the most.

## Recommendation

**Go on with the model, with its own candidates.** The gain is too big to leave: typos fixed 3.7 times as
often, a tenth more sentences right, and next words where Rime has none. The cost per key is fixable.

**Where:** a step in core/ around the Rime engine (`src/rime.cpp`), as the harness does it. Not a librime
plugin or a Rime filter or translator in C++:

- **One copy.** core/ already builds llama.cpp and `engines/sebtype-lm` for English (`SEBTYPE_ENGLISH`), and the
  Chinese model can share both. A librime plugin would need building per platform against each librime:
  - Fedora's on Linux, loaded through `rime-plugins`;
  - the one built from source for Android and Windows.

  It would also carry its own copy of llama.cpp.
- **The engine thread fits it.** core/ already runs 中 and 日 on one engine thread, off the main thread (#241).
  English already computes on a worker thread and announces results through the `ready` callback. The same
  pattern lets Rime's own candidates show at once (3.4 ms p95) and the model's order follow when it is done.
  The key never waits for the model, and the phone's 中 key → candidates budget (≤ 50 ms p95, §5 of the plan)
  holds for Rime's list.
- **Next words** need nothing from Rime: after a commit, core/ asks the model, as English does.

**What the real implementation needs beyond the harness:**

1. **An asynchronous re-rank.** Rime's page first, then the model's order and candidates when they arrive.
   Drop a result whose letters are stale. Only the first page changes, and only if the user hasn't moved on.
2. **A cheaper beam.**
   - Keep the beams between keys: the letters only grow, so most of the last key's search still holds.
   - Stop when Rime's first candidate already wins.
   - Threads: the phone has more than one core for it.

   Each of these targets the 42 ms p95. Then measure on the phone (Nothing A001) with `android/perf`.
3. **Committing a candidate of the model's own.** Rime doesn't know these, so core/ commits the text and
   clears Rime's composition. Rime then learns nothing from the commit. Teaching Rime's user dictionary the
   words (through librime's levers API) would be part of that issue. The user's learned words
   should also stay ranked high: the harness's empty user folder doesn't test that.
4. **简/繁:** OpenCC over the model's candidates when 繁 is on, as rime-ice's own simplifier does.
5. **Memory:** a smaller KV cache, and on the phone, loading the model on the first 中 key, as English does.
6. **Next round of training,** only if wanted later:
   - more chat text, since news and Wikipedia make up most of it;
   - the user's typo mix measured on the PCs' keyboard (this one is the phone's);
   - a larger model, only if the faster search leaves room for it.

**Licence.** The model file isn't committed and doesn't ship. If it ever does, it follows Decisions 6's reasoning
for the English model: CC BY-SA 4.0, because part of its text (Wikipedia) is share-alike, and NOTICE credits
every source in `tools/chinese-lm/SOURCES.md`. The harness and training scripts are MIT. The best checkpoint and
GGUF (`r1`) stay in yanglab16's `~/scratch/SebType/259/`.
