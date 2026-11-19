# English: the model's rankings and what a space gets (#320, 2026-11-18)

Since #310 (PR #319), the English engine (`core/src/english.cpp`) types a letter at once. The decoder runs next,
and a worker thread then ranks the decoder's words with SebType's model. A space or Enter that comes while
that ranking is pending waits for it, for up to 400 ms (`kRankWait`). It waits only when the rankings timed so
far say the ranking will come within that time. Otherwise the decoder's rule decides at once. This report
measures how long a ranking takes and how often a space gets the model's correction. The phone's numbers are
added below once they are measured. The emulator's numbers here only show that the measurement works.

## How it is measured

The engine marks its work with Android trace sections (`ATrace_beginSection`, from `android/trace.h`).
`perf.sh` already records Perfetto traces with the keyboard's app tracing on (`atrace_apps`), so it needs no
other channel. Off Android the sections compile to nothing. A counter in the app read through the test field would be a second path with its own plumbing, and it
would give only totals, not when each job ran.

| Section | Thread | Spans |
|---|---|---|
| `SebType rank` | the engine's worker | one ranking of the letters typed |
| `SebType next` | the engine's worker | one next-words job: the other job a ranking can wait behind |
| `SebType load` | the engine's worker | loading the model, once per process |
| `SebType space` | the engine's thread | a space or Enter deciding the word: how long it waited for the ranking. Inside it, an empty section names the outcome: `ready` (the model's ranking had come), `waited` (it came during the wait), `late` (the wait timed out: the decoder's rule), `skipped` (the ranking was expected after 400 ms, so there was no wait: the decoder's rule) or `none` (no ranking was asked for: the model isn't loaded yet) |

`android/perf/jobs.sql` lists every ranking and next-words job in the trace with its own time, including
those that start when the field opens. `android/perf/keys.sql` puts each space's outcome and wait on its tap
(`space`, `space_ms`). A section still open when the trace ends is left out. `table.py` reports, for EN (700 ms per key), fast typing (100 ms per key) and the
20,000-character field (100 ms per key):

- the model's ranking, median / p95, and how many rankings ran;
- its next words, median / p95, the job a ranking waits behind;
- the share of spaces the model's ranking decided (`ready` + `waited`), with every outcome counted;
- a space's wait, median / p95, over the spaces that waited (`waited` + `late`). The other spaces take
  under 0.1 ms.

`perf.sh --english` runs only the install, the first open, EN, fast and long (about 10 minutes on the
emulator), so these numbers don't need the 中 and 日 phases. On a phone: `ANDROID_SERIAL=<serial>
android/perf/perf.sh --english`.

## Emulator (guide35, x86_64 with arm64 code under Berberis)

Release build of this branch (0.1.30-sebtype.168), `RUNS=3`. Berberis translates the arm64 model code, so the
model is far slower than on a phone. These numbers show the measurement works. They are
not the phone's.

| Set | Ranking, median / p95 (n) | Next words, median / p95 (n) | Spaces decided by the model | Space's wait, median / p95 |
|---|---|---|---|---|
| EN, 700 ms per key | 337 / 712 ms (104) | 676 / 1023 ms (29) | 24 of 27 (89 %): ready 24; skipped 3 | none waited |
| Fast, 100 ms per key | 831 / 1193 ms (11) | 859 / 1043 ms (3) | 0 of 18: late 1, skipped 17 | 400 ms (1 space) |
| Long field, 100 ms per key | none finished | 8907 ms (1) | 0 of 18: skipped 18 | none waited |

key → text on screen stayed at 16 / 28 ms (EN), 18 / 35 ms (fast) and 28 / 46 ms (long).

- **EN:** a ranking (about 340 ms) fits in the 700 ms between keys, so 24 of 27 spaces find it ready and
  wait for nothing. The 3 skipped spaces are each run's first word: when the field opens, the model's next
  words for it (about 680 ms) run first, and the ranking queues behind them.
- **Fast:** at 100 ms per key a new letter replaces the pending ranking before it finishes, so only 11
  rankings ran for 88 keys. A space almost always expects to wait longer than 400 ms and skips the wait.
  The one that waited timed out.
- **Long field:** the next words for the 20,000-character field's text took 8.9 s when the field opened. The one ranking queued behind them was still running when
  the trace ended. So every space skipped the wait.

## Phone (nothing-a001, A001, Android 16)

2026-11-18, the owner present: `perf.sh --english` with the release build of PR #357's head before its review fix (95096650d4; the fix changed only `table.py` and the SQL), `RUNS=3`. Its table was recomputed from the saved traces with the merged `jobs.sql` and `table.py`.

| Set | Ranking, median / p95 (n) | Next words, median / p95 (n) | Spaces decided by the model | Space's wait, median / p95 |
|---|---|---|---|---|
| EN, 700 ms per key | 21 / 46 ms (104) | 42 / 51 ms (29) | 27 of 27 (100 %): ready 27 | none waited |
| Fast, 100 ms per key | 24 / 46 ms (70) | 42 / 51 ms (19) | 18 of 18 (100 %): ready 18 | none waited |
| Long field, 100 ms per key | 41 / 105 ms (27) | 456 / 469 ms (18) | 17 of 18 (94 %): ready 7, waited 10; not waited for 1 | 97 / 249 ms (10 spaces) |

key → text on screen: 16 / 23 ms (EN), 15 / 20 ms (fast), 25 / 82 ms (long). key → keyboard idle in EN: 49 / 66 ms.
No janky keyboard frames in fast or long typing. EN had 4 keyboard frames past their deadline.

- **EN and fast:** a ranking takes about 20 ms on the phone, against 340 ms on the emulator, so every
  space finds the model's ranking ready, even at 100 ms per key, and none waits.
- **Long field:** the next words for the 20,000-character text take about 460 ms each, and a ranking queues
  behind them. So 10 of 18 spaces wait for the ranking, 97 ms at the median and 249 ms at p95, and the space
  shows that much later. One space expected too long a wait and took the decoder's rule. #359 made the
  long field's next words cheaper (below). The phone run after it (2026-11-19, release 181) ran the
  keyboard on the little cores only and can't show the gain: next words 192 ms in EN and 264 ms in the long
  field ([2026-11-19-phone-release.md](2026-11-19-phone-release.md)).
- The emulator's key → idle (about 330 ms median in #351) is Berberis: on the phone it is 49 ms.

## The long field's next words (#359)

**Cause.** The model reads the last line before the cursor, at most 300 characters of it from a word's start
(`engines/sebtype-lm/sebtype_lm.cpp`). That start moved with every word typed, so the window's first tokens
changed and the cache, which keeps only the tokens a new text starts with, kept just `<s>`. Each job decoded
the whole window again, about 70 tokens of the long field's text, against a word or two in a short field.

**Fix.** The window's start stays where the last window started while the window is 150 to 300 characters
long, so a job decodes only the words typed since the last one. Past 300 characters it starts again 150
characters back, at a word's start: one job in about 25 words decodes the window again, as does the first
job in a long field. The start is found by the last window's text, not by its offset, because the engine
keeps the field's last 1,000 characters and cuts them again whenever it reads the field.

**Host** (`engines/sebtype-lm/bench/bench.sh`, yanglab16, one thread, the perf test's 88 characters after an
empty field and after the 20,000-character filler, the filler cut to its last 1,000 characters at every
space; 18 next-words jobs each):

| Next words, median / p95 | Short field | Long field |
|---|---|---|
| Before | 10.8 / 13.1 ms | 58.5 / 59.2 ms |
| After | 11.1 / 13.3 ms | 12.3 / 36.5 ms (the p95 is the one job that starts the window again) |

Rankings stayed at about 7 ms in both. **Quality**, from the same script: 60 Wikinews articles, every second
word more than 300 characters into a paragraph (2,912 words), typed word by word:

| Window | Next word first | In the top 3 | Tokens decoded per job |
|---|---|---|---|
| The last 300 characters (before) | 28.6 % | 43.4 % | 22.4 |
| 150 to 300 characters, start kept (after) | 28.4 % | 43.4 % | 2.1 |
| 150 to 300, start kept every 100 / a fixed 150 / a fixed 100 | 28.2 / 28.1 / 27.1 % | 43.6 / 42.5 / 41.0 % | 2.7 / 18.9 / 14.3 |

The English harness (`android/test/english/run.sh`) gives the same results on every row before and after:
its contexts are all under 200 characters, which the window never cuts. Next word in the top 3: chat 41.7 %,
news 43.7 %, text messages 29.1 %.

**Emulator** (guide35, `perf.sh --english`, release 0.1.30-sebtype.177, `RUNS=3`):

| Next words, median / p95 (n) | EN, 700 ms per key | Fast, 100 ms per key | Long field, 100 ms per key |
|---|---|---|---|
| Before (0.1.30-sebtype.168, above) | 676 / 1023 ms (29) | 859 / 1043 ms (3) | 8907 ms (1) |
| After | 687 / 1005 ms (29) | 854 / 1097 ms (4) | 3002 / 4693 ms (2) |

The emulator can't show the phone's gain in the long field. Under Berberis a job takes seconds, and at 100 ms
per key about 45 characters are typed during each one. A trace of the tokens each job decoded (a temporary
build) showed what the cache does there: the field's first job decoded the 150-character window (49 tokens,
5 s). The ranking after it decoded the 48 tokens typed meanwhile, the next ranking started the window again,
and the last next words decoded the 11 tokens typed since. So each job decodes only what is new, but on the
emulator that is a lot. On the phone, with jobs about 15 times faster, a job decodes a word or two, as in a
short field.
