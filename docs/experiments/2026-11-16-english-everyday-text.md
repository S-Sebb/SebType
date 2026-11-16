# Experiment: everyday English for the English model (#266, 2026-11-16)

SebType's English model (r2, `engines/sebtype-lm/english.gguf`, [tools/english-lm](../../tools/english-lm/README.md))
learns from Wikipedia, Wikinews, oasst2, Dolly and SODA. SODA's dialogues are machine-written, and none of these
sources is real everyday typing: short messages to people, chat, slang, "u", "lol", no apostrophes. This
experiment looked for openly licensed everyday English that the model may be trained on (CC BY-SA 4.0,
docs/plans/android-own-keyboard.md, Decisions 6). It also adds a texting test set to the English harness and
measures today's stacks on it. The retraining that followed (r3, [Results](#results-the-retrained-model-r3-2026-11-16))
gained on the texting sets but fixed fewer misspellings, so r2 stays; the dictionary now has common texting forms.

**Summary.** Real everyday English under an open licence is scarce. Only one source is real texting: the
**NUS SMS Corpus** (CC BY 4.0), 55,835 text messages and 447k words after cleaning. That is small: a few
million tokens at most, against r2's 1.9B per training set. Three crowd-chat sources are also usable:
**Blended Skill Talk** (CC BY 4.0, 1.0M words), **Topical-Chat** (CDLA-Sharing 1.0, 4.6M words) and
**Tatoeba** (CC BY 2.0 FR, 10.8M words without its stock names). They are people typing casually, but to
order, not real messages. The large casual sources (Reddit, Twitter, OpenSubtitles, DailyDialog, Stack
Exchange's current dumps) are all ruled out by their licence or the site's terms.

On the new texting sets, from held-out NUS messages, r2 has the next word in its top 3 for **29.1 %** of words
(today's FUTO stack 26.9 %), against 41.7 % on the oasst chat sentences. It fixes **71.4 %** of phone typos in
text messages (today 69.0 %), against 84.0 % on the chat and news typos. The gap is mostly in ordinary words
in a texting context, not in texting forms, which are 3 % of the items. Adding the sources below should
narrow it by a few points: my estimate is +2 to 5 points of next words and +1 to 3 points of typos fixed on the
texting sets, and no change on the other sets. A larger gain would need either much more real text, which
doesn't exist under these licences, or texting-style noise added to the existing chat sources
([below](#expected-change)).

## Candidate sources

Each licence was checked at the source on 2026-11-16, at the revision given. "Usable" means compatible with
releasing the model under CC BY-SA 4.0, as attribution-only and share-alike data are (NOTICE credits each).

| Source | Licence (where checked, revision) | Size (English) | Style | How collected | Personal data | Verdict |
|---|---|---|---|---|---|---|
| [NUS SMS Corpus](https://scholarbank.nus.edu.sg/handle/10635/137343), 2015-03-09 release | CC BY 4.0 (`dc.rights.uri` on NUS ScholarBank's record; files from the authors' [GitHub](https://github.com/kite1988/nus-sms-corpus) at `bf0a3651`, as ScholarBank's copy needs an access request) | 55,835 messages, 581k words; 42,611 lines and 447k words after `corpus.py`'s cleaning | real SMS, collected from 2003 on: "u", "lol", "dunno", lowercase, missing apostrophes. 64 % from Singapore and 16 % from India, so much Singlish ("lah", "lor", "liao") and Indian texting; 11 % from the US (6,700 messages, 32 senders from English-speaking countries) | volunteers' own sent messages, who knew they would be published (Chen & Kan 2013) | numbers, times and email addresses replaced by `<#>`, `<TIME>`, `<EMAIL>`; first names are not always removed | **usable, the only real texting** |
| [Blended Skill Talk](https://github.com/facebookresearch/ParlAI/tree/main/parlai/tasks/blended_skill_talk) | CC BY 4.0 (`LICENSE_DOCUMENTATION` in ParlAI at `a29567f7`) | 77,502 turns, 1.04M words | casual chit-chat as typed, with capitals and apostrophes | Mechanical Turk workers chatting in pairs | personas are invented | **usable** |
| [Topical-Chat](https://github.com/alexa/Topical-Chat) | CDLA-Sharing 1.0 (`DATALICENSE` at `7c939229`); §3.5: no restrictions on Results such as a trained model | 235,281 turns, about 4.6M words (19.6 per turn) | chat about given topics (news, Reddit's TIL, Wikipedia), as typed; more formal and fact-heavy than texting | Mechanical Turk workers chatting in pairs | none collected | **usable** |
| [Tatoeba](https://tatoeba.org/en/downloads) | CC BY 2.0 FR, part CC0 (downloads page and terms of use, 2026-11-16 export) | 2.04M sentences, 15.8M words; 1.39M and 10.8M without the stock names Tom, Mary and the like | short everyday sentences with contractions ("You don't even know why I'm here, do you?"), but made-up examples, and every third one names Tom or Mary | volunteers writing example sentences for learners; many from the public-domain Tanaka Corpus | usernames are in a separate column, not in the text | **usable, at a low weight** |
| [WildChat-1M](https://huggingface.co/datasets/allenai/WildChat-1M) (user turns only) | ODC-BY (dataset card at `7d6490e4`; ImpACT before 2024-06) | 838k conversations; about 1M English user turns (8M words in one of 14 shards); about 7M words in one-line turns of up to 30 words | real people typing casually, with typos, but to ChatGPT: requests, role-play, code. Like oasst2's prompts | logged from a free ChatGPT service with the users' consent | de-identified with Presidio and by hand; flagged conversations removed | usable, not recommended: it adds little that oasst2 doesn't have |
| [PersonaChat](https://github.com/facebookresearch/ParlAI/tree/main/parlai/tasks/personachat) / ConvAI2 | CC BY 4.0 (`LICENSE_DOCUMENTATION`, ParlAI `a29567f7`) | 162,064 turns, 1.9M words | crowd chit-chat, but only as preprocessed text: lowercased, punctuation split off, every apostrophe and contraction expanded ("i am", "do not") | Mechanical Turk workers | personas are invented | not as it is: it would teach the model the wrong forms |
| [UCI SMS Spam Collection](https://archive.ics.uci.edu/dataset/228/sms+spam+collection) | CC BY 4.0 | 4,827 real messages | SMS | 3,375 of them are NUS's; the spam was taken from the Grumbletext forum | phone numbers not removed | no: a subset of NUS, plus unremoved numbers |
| Stack Exchange dumps | CC BY-SA, but the dumps since July 2024 come with an agreement not to use them for LLM training | large | technical Q&A and comments | site dump | usernames | no: against the site's download terms (and not everyday) |
| Reddit (Pushshift and others), Twitter/X, Discord, Hacker News | the sites' terms forbid or don't license reuse | large | the most everyday text there is | scraped | heavy | no |
| OpenSubtitles (OPUS), Cornell Movie-Dialogs | no licence from the films' rights holders | large | scripted speech | scraped | no | no |
| DailyDialog | CC BY-NC-SA 4.0 | 13k dialogues | everyday dialogue written by learners | — | — | no: non-commercial |
| EmpatheticDialogues | CC BY-NC 4.0 | 25k dialogues | crowd chat about feelings | — | — | no: non-commercial |
| Santa Barbara Corpus of Spoken American English | CC BY-ND 3.0 US | 249k words | transcribed conversation | — | — | no: no derivatives |
| Ubuntu Dialogue Corpus / Ubuntu IRC logs | the scripts are Apache-2.0; the logs have no licence | large | technical chat | — | nicknames | no: unclear |
| LMSYS-Chat-1M, Switchboard, Fisher, the Enron e-mails | their own agreements, LDC's licence, no licence | — | — | — | — | no |

## The texting test sets

`android/test/english/make_sets.py texts` makes two sets from held-out NUS messages:

- `next-texts.tsv`: 2,618 next-word items, every lowercase word after the first in 400 messages, words of one
  letter included ("u", "i").
- `text-typos.tsv`: 1,000 phone-typo items, one word of three letters or more from each of 1,000 other
  messages, with #46's typo mix and the same touch model as `phone-typos.tsv`.

The messages come only from senders in the US, Canada, the UK, Australia and New Zealand, as written,
including their typos in the context. No sender gives more than 15 % of them. A word typed without its
apostrophe means the word with it when the dictionary has only that one ("dont" → "don't", "im" → "I'm"),
because a keyboard should commit that.

**No personal data.** NUS already replaced numbers and email addresses. A message is also left out if it has
a digit, a placeholder or one of `@#/<>_`, or a capital in mid-sentence other than I. It is left out too if it
has a word that is a name more often than not in `data/en-dict/en_US.dict` ("John", "Mike", "Monday"), or a word
in neither the dictionary nor the messages of 5 senders, which catches a friend's name or a street. Of the 6,688
messages from those countries, 2,566 pass. I read the 89 distinct words of the sets that aren't in the
dictionary: they are texting forms ("u", "lol", "tmrw", "imma") and interjections, with no names among them.

**Held out from training.** `sets/nus-sms-held-out.txt` lists the 1,400 message ids. `corpus.py` now reads NUS
(`nus_sms()`, fetched by `fetch.sh`) and leaves those messages out, and every other message with the same
words. Its n-gram filter also drops any line sharing a 5-to-8-word run with any harness item. NUS isn't in
`pack.py`'s MIX yet, so the next training is unchanged until MIX names it. On the full corpus, 0 of the 1,664
messages with those ids (some ids repeat) reach the training lines; without the id filter, 809 would.

One caveat: the held-out messages' senders also wrote training messages, so a model trained on NUS knows their
habits. Holding out by sender isn't practical, because four senders wrote 70 % of the English-speaking
countries' messages. A gain on `next-texts` after adding NUS will therefore read a little high. Check it
against `next-chat`.

## Baseline

`android/test/english/run.sh` with the committed r2 model, on yanglab16. Both runs gave the same quality
numbers. Its `reproducible` check failed on latency alone (AOSP's per-key p50 on clean words 2.06 against
1.18 ms), as the shared machine was busy. The rows of the existing sets match
[docs/perf/2026-11-15-english.md](../perf/2026-11-15-english.md) exactly, and the bar passes.

| Measure (set, items) | Today: FUTO's decoder + transformer | Pristine AOSP decoder + AOSP's dictionary | Pristine AOSP decoder + SebType's dictionary | Pristine AOSP decoder + SebType's model (r2) | New keyboard: core/'s English + rebuilt dictionary |
|---|---|---|---|---|---|
| Typo fixed: a space commits the intended word (phone typos, 1,000) | 80.7 % | 71.1 % | 70.6 % | 84.0 % | 83.5 % |
| Intended word first / in the top 3 (phone typos) | 85.2 / 93.4 % | 79.6 / 91.1 % | 79.1 / 92.1 % | 91.7 / 95.3 % | 91.7 / 95.3 % |
| **Typo fixed: a space commits the intended word (phone typos in text messages, 1,000)** | 69.0 % | 57.9 % | 62.3 % | 71.4 % | 71.9 % |
| **Intended word first / in the top 3 (phone typos in text messages)** | 75.7 / 88.4 % | 70.2 / 86.8 % | 75.8 / 89.2 % | 83.6 / 90.3 % | 84.6 / 91.2 % |
| Next word in the top 3, nothing typed (chat sentences, 2,701 words) | 37.8 % | 0.0 % | 0.0 % | 41.7 % | 41.7 % |
| Next word in the top 3, nothing typed (news sentences, 1,927 words) | 32.1 % | 0.0 % | 0.0 % | 43.7 % | 43.7 % |
| **Next word in the top 3, nothing typed (text messages, 2,618 words)** | 26.9 % | 0.0 % | 0.0 % | 29.1 % | 29.1 % |

The other rows (misspellings, clean words, latency) are unchanged from the 2026-11-15 table.

**Where r2 loses on texts** (run 1, SebType's model stack):

- Next words: 30.2 % for ordinary words, 2.4 % for texting forms ("u", "lol", "ok", "gonna"; 83 items) and
  0 of 12 apostrophe words written without one. Ordinary words are 96 % of the set, so the 12-point gap to the
  chat set lies almost wholly in ordinary words after personal, everyday contexts ("Did she forget her phone
  for the day ___").
- Typos: 73.0 % fixed for ordinary words, 15 % for texting forms (20 items), 22 % for "dont"-style words (9).
  The gap holds at every length (3-4 letters: 69.9 % against 81.9 % on `phone-typos`; 5 or more: 73.7 against
  85.8 %). 218 of the 286 misses leave the typed letters as they are: in a texting context, the model is less
  sure that a space should change the word.
- **The dictionary has no texting forms.** `data/en-dict/en_US.dict`, which the new keyboard's decoder uses, has
  no "u", "ur", "lol", "ok", "omg", "btw", "thx" or "tmrw". Those are 87 of the 2,618 next-word targets and 12
  of the 1,000 typo targets, so core/ can't offer or correct them whatever the model learns. That is a dictionary
  fix ("dont" and "im" are there, as shortcuts to "don't" and "I'm"), separate from retraining. I didn't file an
  issue for it; it is the user's call whether "u" and "lol" should be offered.

## Recommended mix

r2's packed training set is about 1.9B tokens (8B trained over three packs, about 1.4 epochs). Wikipedia makes
up most of it; SODA, oasst2 and Dolly together are roughly a seventh (my estimate from the sources' sizes:
r2's corpus files are gone). Proposed MIX in `tools/english-lm/pack.py`
(passes over each corpus file per training set), with the new sources' readers to be added to `corpus.py` and
`fetch.sh` when retraining:

```python
MIX = {
    "wikipedia": 0.35,
    "simplewiki": 1.0,
    "wikinews": 3.0,
    "soda": 1.5,
    "oasst2": 4.0,
    "dolly": 3.0,
    "nus-sms": 4.0,       # new: 0.45M words -> 1.8M words a pack
    "bst": 3.0,           # new: Blended Skill Talk, 1.0M -> 3.1M
    "topical-chat": 1.5,  # new: 4.6M -> 6.9M
    "tatoeba": 0.5,       # new: 10.8M (without Tom, Mary and the like) -> 5.4M
}
```

That adds about 17M words a pack, about 1 % of it, so nothing else needs to shrink. NUS is capped at 4 passes:
with three packs and 1.4 epochs, each message is seen about 17 times, and more would let a 36M model memorise
individual messages. For NUS's training lines, I'd also drop messages with Singlish particles ("lah", "lor",
"leh", "liao") or keep NUS at the weight above. Its Singaporean share would otherwise make those words rank
for everyone. Tatoeba's stock names have to go, or "Tom" becomes the model's favourite next word.

## Expected change

My estimate, not a measurement: +2 to 5 points on `next-texts` (29.1 % now) and +1 to 3 on `text-typos` fixed
(71.4 %), with `next-chat`, `next-news` and the typo sets within a point. The reasoning:

- The new data is about 1 % of training, and only NUS (0.1 %) is real texting. SODA, about a tenth of it, hasn't made
  r2 good at texts. A small, well-matched source moves a model's rare contexts more than its share suggests,
  but it can't make texting the model's home register.
- Texting forms (3 % of the items) need the dictionary change above in core/; without it, no retraining helps
  them on the new keyboard.

Two cheaper levers would likely matter more than any source left. Both are for the retraining step:

1. **Texting-style noise in `pack.py`**, as it already writes typo examples: in a share of the chat sources'
   lines, lowercase the first letter, drop apostrophes ("dont", "im") and capitals, and use "u", "ur", "pls",
   "lol". That teaches the model texting contexts from the chat it already has (SODA alone has 1.5M dialogues). The real NUS
   messages then show it the true mix.
2. **Adding the texting forms to the dictionary** (`data/en-dict/make_dict.py`), so core/'s decoder can offer
   "u", "lol" and "ok" at all.

A retrain can then be judged on the new rows. `next-texts` and `text-typos` should rise, and §2's bar on the
other sets must still pass.

## Results: the retrained model, r3 (2026-11-16)

The user's answer was "Retrain with both": the four sources and texting-style noise, with r3 replacing r2 only
if no harness set gets worse beyond noise and the texting sets improve. **r3 doesn't pass: it fixes fewer
Wikipedia misspellings (39.6 % against 43.0 %), so the committed model stays r2.** The texting words in the
dictionary, measured on their own, change nothing else and ship.

**What changed in training** (`tools/english-lm`, r3's recipe): MIX as recommended above, with these corpora:

- NUS SMS: 20,743 training lines (1,074 more held out for the dev sets). Besides the harness's messages, left out
  are messages with Singlish particles and messages with a word that is neither a lowercase dictionary word nor
  used by 5 senders, which catches the first names NUS left in ("andreu", "sophie").
- Blended Skill Talk: 67,314 lines, only the crowd workers' own turns (its seed turns come partly from
  EmpatheticDialogues, which is non-commercial). Topical-Chat: 185,600 lines. Tatoeba: 1,132,527 sentences,
  without any that holds a word Tatoeba capitalises mid-sentence more often than not (Tom, Mary, Sami, places).
- Texting style: in 20 % of SODA's, Blended Skill Talk's and Topical-Chat's lines, sentences start in lowercase,
  and "I", apostrophes and full stops are often dropped. Common words take short forms ("u", "ur", "pls",
  "gonna", "idk"; `pack.py`).
- Everything else as r2: its tokenizer, config (8B tokens over three packs), seed and `decide()` weights.

`overlap.py`: 0 corpus lines share 8 words with a harness item, and 0 harness items of 5 words or more are in the
corpus. Of the 1,400 held-out NUS messages, none is in the NUS training lines. 132 short ones ("I love you.",
"Where are you?") also occur in other sources as ordinary English.

**Choosing the texting share on the dev sets.** Three 1B-token models from the same packed text, differing only
in the share (`dev_sets.py` adds texting dev sets from held-out NUS messages; dev numbers, decide()'s weights as
committed):

| Dev set | share 0 | 0.2 | 0.4 |
|---|---|---|---|
| next-texts top 3 (1,290 words) | 16.7 % | **18.4 %** | 18.3 % |
| text-typos fixed (732) | 61.1 % | **62.8 %** | 62.6 % |
| next-chat / next-news top 3 | 40.4 / 42.6 % | 40.7 / 41.7 % | 39.9 / 41.2 % |
| phone-typos fixed (1,633) | 84.9 % | 84.1 % | 83.8 % |
| misspellings fixed (1,500) | 52.7 % | 52.1 % | 49.1 % |
| clean changed (4,574) | 0.1 % | 0.1 % | 0.0 % |

0.2 gives most of the texting gain at the least cost elsewhere. On the dev sets, r3 against r2: next-texts 15.4 →
19.2 %, text-typos fixed 61.9 → 62.2 %, next-chat 45.2 → 44.9 %, next-news 44.7 → 45.2 %, phone-typos fixed
85.5 → 85.2 %, misspellings fixed 52.3 → 49.3 %. The misspellings loss already showed there.

**The harness** (`run.sh` on yanglab16, the new keyboard's stack, core/). The quality numbers of each run's two
passes agree; its `reproducible` check failed on latency only, as other jobs shared the machine. "Paired" counts
the items only the old or only the new configuration gets right, with an exact sign test.

| Measure (set, items) | r2, today's dictionary | r2 + texting words | r3 + texting words | Paired: only r2 / only r3 right |
|---|---|---|---|---|
| Typo fixed (phone typos, 1,000) | 83.5 % | 83.5 % | 83.4 % | 25 / 24, p 1.0 |
| Intended word first / in the top 3 (phone typos) | 91.7 / 95.3 % | 91.7 / 95.3 % | 91.3 / 95.0 % | |
| **Typo fixed (phone typos in text messages, 1,000)** | 71.9 % | 71.9 % | **73.8 %** | 29 / 48, p 0.04 |
| Intended word first / in the top 3 (text messages) | 84.6 / 91.2 % | 84.8 / 91.5 % | 85.4 / 92.1 % | |
| **Typo fixed (Wikipedia misspellings, 1,500)** | 43.0 % | 43.0 % | **39.6 %** | 164 / 113, p 0.003 |
| Intended word first / in the top 3 (misspellings) | 83.3 / 88.5 % | 83.3 / 88.5 % | 83.6 / 88.6 % | |
| Correct word wrongly changed (clean words, 1,000) | 0.2 % | 0.2 % | 0.2 % | 0 / 0 |
| Next word in the top 3 (chat sentences, 2,701) | 41.7 % | 41.7 % | 41.9 % | 123 / 127, p 0.85 |
| Next word in the top 3 (news sentences, 1,927) | 43.7 % | 43.7 % | 43.7 % | 82 / 81, p 1.0 |
| **Next word in the top 3 (text messages, 2,618)** | 29.1 % | 29.1 % | **30.6 %** | 123 / 160, p 0.03 |
| Per key, ms p95, clean / phone typos (run 1) | 16.8 / 21.1 | 21.3 / 23.8 | 18.6 / 20.1 | same size and shape |

SebType's model on AOSP's decoder moves the same way: misspellings fixed 43.6 → 39.9 %, text-typos 71.4 →
73.0 %, next-texts 29.1 → 30.6 %. r3 has r2's shape and size, so its latency is r2's; the p95s above move
with the machine's load (r2's two runs differ as much).

**Where r3 loses.** It ranks the intended word first as often as r2 (83.6 against 83.3 %). It loses on the
commit: with no context, it is less sure that a space should change letters that aren't a word, and more often
leaves them. That fits what it learned from real messages, where words are often left misspelt or shortened.
The gains are the reverse: in texting contexts, r3 keeps and predicts the texting forms. Typed on their own
after seven everyday contexts, the 26 texting words are kept by a space 179 times of 182 with r3. r2 keeps them
155 times; it turns "lmao" into "Lao", "omw" into "one" and "ppl" into "pop".

**The texting words** (`data/en-dict/make_dict.py`): u, ur, ok, lol, omg, btw, idk, thx, tmrw, lmao, brb, ttyl,
nvm, ppl, cuz, tbh, hahaha, hehe, xoxo, bday, txt, plz, ikr, omw, lmk, smh. They get wordfreq's weight, capped at
90 (about the 85th percentile of the list; "the" is 222). The words they look like keep theirs, so none is pushed
out. A higher cap (110, or none) keeps the same words and only offers more of them as completions. With r2,
adding them changes no harness number but text-typos' first and top-3 rates (+0.2 and +0.3 points). Typed on
their own, they are kept 155 times of 182 instead of 127.

**Not tried: the commit margin.** On the dev sets, `decide()`'s margin for letters that aren't a word
(MARGIN_NON_WORD, 12) is far from the best for either model. At 6, dev misspellings fixed rises from 52 to 78 %
(r2) and from 49 to 78 % (r3), with phone and text typos up too and changed correct words still 0.1 %. That is a
change to the ranking, separate from this training, and needs the harness's own check (r1's looser weights
changed more correct words), so it isn't part of this result (#291).
