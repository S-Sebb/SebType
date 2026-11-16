# Experiment: a small Chinese model on top of Rime (#259, 2026-11-16)

Today's 中文 is Rime: rime-ice, 白霜's dictionary, the zh-moqi octagram grammar and SebType's typo Lua, the data
the apps ship. The question was whether a small Chinese transformer, trained from scratch on openly licensed
text, beats it at three things, at about the English model's size and speed (about 30 MB, p95 under 20 ms per
key): the first candidate, pinyin typo fixes, and the next word after a commit.

**Summary.** It does, clearly. On one thread it still costs more time per key than the target at full
strength, but it fits on 4. The model is 17 MB (16.6M parameters, Q6_K), trained in 41 minutes on one H100.
Two ways of using it were measured:

- **Re-ranking Rime's first 4 candidates** fits the budget: 8.5 / 14.2 ms per key at p50 / p95. It helps
  abbreviations (news: 23.2 → 36.8 % first) and the last syllable cut short (chat 52.5 → 67.2 %, news 56.8 →
  70.8 %), but not typos (14.5 → 18.8 %) or full sentences (60.9 → 61.6 %). Rime seldom offers the right text
  for those, so there is nothing to promote.
- **Adding the model's own candidates** (a beam of 2 from the letters) wins everywhere. Typos are fixed at
  rank 1 for 57.7 % instead of 14.5 %, in the top 3 for 68.3 % instead of 18.9 %. Full-pinyin sentences are
  right for 74.1 / 76.0 % (chat / news) instead of 60.9 / 65.5 %. It costs 12.4 / 25.5 ms per key at p50 / p95
  on one thread, and 8.9 / 17.8 ms on 4.
- **Next words** with nothing typed: 32.5 % (chat) and 27.2 % (news) in the top 3, where Rime predicts nothing.

#265 profiled the cost per key and cut the waste ([where the time goes](#where-the-time-goes)). It found a
bug that also cost quality: every text the model read began with a token it never saw in training. Fixing it
raised almost every measure above; the weights were then tuned again on the dev sets. News's next words fell
from 27.5 to 27.2 %. Before #265, in runs back to back with #265's first ones, the third column cost 19.5–19.8 /
39–40 ms per key and fixed 53.1 % of typos.

Two runs gave the same results item by item, but for the clock's time, which rime-ice offers for `sj`.
**Recommendation:** go on with it, as its own step in core/ on the engine thread, not as a librime plugin
([below](#recommendation)).

## Results

`android/test/chinese-lm/run.sh` on yanglab16, run 1 with run 2's latency in brackets, after #265. All three
columns run the same Rime build and data. The second column uses `rerank=4 rankWeight=0`, and the third
`rerank=4 generate=2 rankWeight=0.5 generatedRank=4`, tuned on the dev sets after #265's fix
([how](#how-the-model-and-rime-combine)). Rates are percentages of the set's items.

| Measure (set, items) | Today: Rime, rime-ice + 白霜 + octagram | Rime, re-ranked by SebType's Chinese model | … and the model's own candidates |
|---|---|---|---|
| Sentence right at rank 1, full pinyin (chat, 800 clauses) | 60.9 % | 61.6 % | 74.1 % |
| Words right in the first candidate (chat) | 85.2 % | 85.0 % | 90.0 % |
| Sentence right at rank 1, full pinyin (news, 800 clauses) | 65.5 % | 65.6 % | 76.0 % |
| Words right in the first candidate (news) | 87.3 % | 87.1 % | 91.4 % |
| Word first / in the top 3, abbreviated, zd → 知道 (chat, 400) | 23.0 / 35.0 % | 30.2 / 39.2 % | 44.2 / 61.8 % |
| Word first / in the top 3, abbreviated, zd → 知道 (news, 400) | 23.2 / 41.0 % | 36.8 / 48.0 % | 40.2 / 58.8 % |
| Word first / in the top 3, last syllable abbreviated, ranh → 然后 (chat, 400) | 52.5 / 70.0 % | 67.2 / 73.2 % | 73.5 / 84.5 % |
| Word first / in the top 3, last syllable abbreviated, ranh → 然后 (news, 400) | 56.8 / 75.8 % | 70.8 / 77.5 % | 74.8 / 86.2 % |
| Typo fixed: intended text first / in the top 3 (phone typos and confusions, 799) | 14.5 / 18.9 % | 18.8 / 19.3 % | 57.7 / 68.3 % |
| … first, zh/z, ch/c, sh/s, ng/n confused | 4.7 % | 5.5 % | 56.2 % |
| … first, a letter doubled | 1.8 % | 7.0 % | 73.7 % |
| … first, a letter left out | 10.6 % | 11.7 % | 48.4 % |
| … first, a neighbouring key | 25.7 % | 33.4 % | 63.7 % |
| … first, two letters swapped | 15.2 % | 15.2 % | 66.7 % |
| … first, two typos | 4.9 % | 9.8 % | 43.9 % |
| Next word in the top 3, nothing typed (chat, 1500) | 0.0 % | 32.5 % | 32.5 % |
| Next word in the top 3, nothing typed (news, 1000) | 0.0 % | 27.2 % | 27.2 % |
| Per key, ms p50 / p95 (run 2 in brackets) | 1.2 / 3.38 (1.26 / 3.66) | 8.54 / 14.24 (8.54 / 14.32) | 12.44 / 25.51 (12.22 / 25.06) |
| … on 2 threads | | 7.4 / 12.6 | 10.74 / 21.43 |
| … on 4 threads | | 5.79 / 10.22 | 8.86 / 17.84 |
| Per next-word prediction, ms p50 / p95 | 0.0 / 0.0 | 6.68 / 10.8 | 7.19 / 11.98 |
| Peak RSS of the process | 43 MB | 82 MB | 83 MB |

What the model fixes is mostly context. Of the 800 chat clauses, the third column gets 140 right that Rime gets
wrong, and 34 the other way round. Examples:

| Typed | Rime's first | With the model |
|---|---|---|
| najiuyizhizhuchixiaqu | 那就抑制住吃下去 | 那就一直主持下去 |
| buyaoxiawoa | 不要下我啊 | 不要吓我啊 |
| woyouzhegerongxingma | 我又这个荣幸吗 | 我有这个荣幸吗 |
| shiyuanxiaokaichechumenma | 是院校开车出门吗 | 是元宵开车出门吗 |

Next-word timings vary most with the machine's load: the same code took 10.3–10.9 / 18.8–20 ms in #265's
first runs, and 7.2 / 11.8 ms in #259.

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
2. Decodes, in one batch, the letter just typed and `<S>` (the KV cache keeps the context and the letters
   before it), and after them every candidate as a branch of a tree. The model's own candidates from the last
   key go in the tree too, unscored. Each branch's logits are kept for the steps below.
3. Scores each candidate as log P(candidate, then `<E>` | context `<T>letters<S>`) from those logits.
4. With `generate`, adds its own candidates: a beam search of that width from `<S>`. At each step every beam
   ends at `<E>` as a candidate, and goes on with its likeliest Han characters, of which the search keeps the
   best `width`. It stops when `width` candidates beat every beam left. A step that stays on the tree costs
   nothing; the others decode one character for all beams at once. Its candidates' scores come from the
   search itself.
5. Ranks them all by the score minus `rankWeight · ln(1 + Rime's rank)`, where a candidate of the model's own
   counts as Rime's rank `generatedRank`. Rime's later candidates follow in Rime's order.

Text goes to the model one piece per character, as training wrote it (`pack.py`), not through
`llama_tokenize`, which starts every text with a `▁` the model never saw ([below](#where-the-time-goes)).

With nothing typed, `nextWords` follows the 8 likeliest first characters and keeps the 6 best prefixes per
length, up to 4 characters. Each prefix is a word with the probability `<B>` gives a word ending at its last
character, and goes on with the probability that none does. The search stops when 3 words beat every live
prefix.

`tools/chinese-lm/tune.py` chose the weights by mean top-1 over the 7 typed dev sets, after #265's fixes. It
reads one dump per beam width, each with Rime's first 10 candidates and the model's own, and tries fewer of
Rime's as zhbench would: a candidate of the model's own that only Rime's later ones matched comes back as the
model's. A beam needs a dump of its own, as a wide search doesn't contain a narrow one's results.

| Dev mean top-1 | Rime's first 2 | 4 | 6 | 10 |
|---|---|---|---|---|
| re-ranked | 43.6 % | 46.6 % | 49.5 % | 50.5 % |
| with a beam of 1 | 58.9 % | 59.0 % | 59.2 % | 59.3 % |
| … of 2 | 60.3 % | 60.4 % | 60.4 % | 60.4 % |
| … of 3 | 60.7 % | 60.7 % | 60.6 % | 60.6 % |
| … of 4 | 60.8 % | 60.7 % | 60.7 % | 60.7 % |

Rime's order alone gets 39.8 %. With the scores right, Rime's order barely helps the model's among its first 4
(the best `rankWeight` is 0). Scoring more of them gains more, but each costs its characters in the batch, and
4 keeps the second column's cost. A beam wider than 2 gains 0.3 points for more steps per key. Before #265, the
same dev sets gave 43.4 % re-ranked and 51.6 % with the model's own candidates.

## Size and speed

| | Rime alone | Re-ranked | With the model's own candidates |
|---|---|---|---|
| Files added | — | 17 MB model | 17 MB model |
| Peak RSS | 43 MB | 82 MB (+39) | 83 MB |
| Per key p50 / p95, 1 thread | 1.2–1.3 / 3.4–3.7 ms | 8.5 / 14.2–14.3 ms | 12.2–12.4 / 25.1–25.5 ms |
| … 4 threads | | 5.8 / 10.2 ms | 8.9 / 17.8 ms |
| Next word p50 / p95 | — | 6.7–10.9 / 10.8–20 ms, by the machine's load | |

Most of the extra memory is llama.cpp's buffers. The KV cache holds 1,024 positions shared by up to 49 sequences,
more than these searches use, so a smaller one would save part of it. It costs no time: llama.cpp attends over
at least 256 cells either way, and skips the empty ones.

### Where the time goes

#265 timed each step of a key (`profile=1`, `score.py --profile`) before changing anything. The table is the
third column's mean per key over all sets, with the slowest 5 % of keys in brackets. Before is main's code with
the timers; after is this code. Both run on 1 thread, 16 processes at a time, on the same day.

| Step | Before | After |
|---|---|---|
| Rime | 2.26 (4.14) ms | 2.27 (4.83) ms |
| Context and letters, decoded on their own | 3.43 (4.16) ms | — (in the next batch) |
| The candidates' batch | 8.02 (15.97) ms | 8.69 (15.35) ms |
| The beam's steps | 7.72 (21.83) ms | 3.13 (9.19) ms |
| Log-sum-exp over the vocabulary | 0.92 (1.87) ms | 0.46 (0.93) ms |
| Cache copies, tokens, the rest | 0.15 (0.50) ms | 0.15 (0.37) ms |
| **Total** | **22.51 (48.47) ms** | **14.71 (30.66) ms** |
| Decodes per key | 6.8 (12.3) | 3.4 (7.5) |
| Tokens decoded per key | 22.7 (44.5) | 15.5 (29.8) |

Re-ranking alone went from 11.20 (21.12) to 9.94 (20.22) ms, with 1 decode per key instead of 2. With the
review's fixes and the new weights, the final runs' profile is 8.92 (16.72) ms re-ranked and 13.92 (29.72) ms
with the model's own candidates, at 3.4 (7.8) decodes per key: the beam's fix below adds no decode. Measured
apart, a decode on one thread costs about 0.5 ms plus 0.6 ms per token. Batching tokens saves the first part,
so the waste was in decodes and tokens:

- **A token the model never saw.** The GGUF says `add_space_prefix`, which llama.cpp's converter writes for
  every SentencePiece model, though this tokenizer has `add_dummy_prefix` off. So `llama_tokenize` began the
  context and every candidate with `▁`. That cost a token per candidate, and every candidate's score was
  some 23 nats lower than it should be: log P(`▁` | `<S>`). The model then read the text after a token it
  had never seen there. The beam's paths, which start without it, also never met the scored texts. Now
  `zh_lm.cpp` tokenizes per character, as `pack.py` does.
- **The letters, decoded twice.** `generate()` and `score()` each decoded the new letter and `<S>`, the
  second only to get `<S>`'s logits back, then the candidates in a third decode. Now one batch does all of
  it.
- **The model's candidates, scored twice.** The beam's own probabilities are the scores. `score()` decoded
  them again.
- **The beam decoding what scoring had decoded.** Scoring now runs first, and a beam step that follows a
  scored text uses its logits.
- **The last key's candidates.** In a long sentence the second beam leaves Rime's candidates and costs a
  decode per character. It mostly follows the last key's candidates again, so those go in the batch too: a
  token there costs about half of a step of its own. This took 1 decode per key off on average, and 2.3 off
  the slowest keys.
- Smaller: the beam scanned the whole vocabulary for Han characters at each step; scoring ran the vocabulary's
  log-sum-exp once per candidate's character rather than once per character of the tree.

What isn't waste:

- **The model's own cost.** About 0.6 ms per token is the model: timed per operation, 63 % is the q8_0
  matrix products, 18 % q6_K and 16 % attention. Q6_K needs rows in blocks of 256, so the 384-wide weights are
  stored as q8_0. Exported as Q8_0 or F16 instead, the model decodes no faster (0.58 ms per token at 32 tokens).
- **Work between keys.** The letters come before `<S>`, so each key changes what every candidate follows.
  Only the context and the earlier letters carry over, and they already did.
- **The 1,024-position cache, unified across sequences, and the batches made per call:** under 0.1 ms.

The slowest 5 % of keys are long sentences (26 letters on average). They need about 30 tokens and 7.5 decodes,
so on one thread they stay above 20 ms. On 4 threads, p95 is 17.8 ms. Going further on one thread needs a beam
that stops earlier, or a smaller or more quantized model, and both change the results.

**Quality.** Each change was measured on its own, at the old weights first:

1. **The `▁` fix**, on main's code, raised almost every measure: typos fixed first 53.1 → 56.8 %, sentences
   70.6 / 71.9 → 74.1 / 75.8 % (chat / news), abbreviations in chat 30.2 → 44.2 %. Two typos in one item fell
   45.1 → 42.7 %.
2. **The speed changes** left the re-ranked column the same item by item. In the third column, 13 items' target
   moved, 8 up and 5 down: sent-chat top 3 84.2 → 84.5 %, sent-news 75.8 / 86.2 → 75.6 / 86.4 %, typos
   56.8 / 68.2 → 57.1 / 68.3 %. The search is the same, so only the numbers can differ, and they do: llama.cpp's
   CPU results depend on the batch's shape. Traced through each of the 13, the first beam step where the two
   builds part chooses between candidates 0.001–0.05 nats apart. In two, the beams agree and the final order
   flips by under 0.03. Against the same texts decoded fresh, one token per decode, main's scores are off by
   0.003 nats at the median (0.07 at most) and this code's by 0.04 (0.10 at most), as its batches are larger.
   So where the model's own candidates differ, it is these near ties, not a change in the search.
3. **The beam's ending** (review of #286). `<E>` used to compete with Han characters for a beam's `width`
   best tokens, so a beam whose end ranked below two characters never became a candidate, and at the last
   step it could finish none. Now every beam ends as a candidate, apart from the characters it goes on with.
   On the dev sets it changed 5 items' top 3 of 2,000 and no target's rank, at either weights.
4. **Tuning again** on the dev sets ([above](#how-the-model-and-rime-combine)) raised the dev mean from 59.4 to
   60.3 %. On the test sets, typos fixed first rose to 57.7 %, abbreviations in news to 36.8 % re-ranked and
   40.2 % with the model's own. A few measures fell by up to 1 point: abbreviations in chat re-ranked
   (31.2 → 30.2 %), typos with a neighbouring key (64.6 → 63.7 %).

## Recommendation

**Go on with the model, with its own candidates.** The gain is too big to leave: typos fixed 4 times as
often, a tenth more sentences right, and next words where Rime has none. The cost per key fits on 4 threads
(17.8 ms p95), and on one thread it is now the model's own compute ([above](#where-the-time-goes)).

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
2. **The loader's per-key flow from #265:** characters tokenized as training does, one batch for the letter
   and the candidates, and the beam on top of it. Then threads: the phone has more than one core for it.
   Measure on the phone (Nothing A001) with `android/perf`. If one thread must do, stop the beam when Rime's
   first candidate already wins. That changes results, so tune it on the dev sets.
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
