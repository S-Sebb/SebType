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

Not measured yet: the orchestrator runs `perf.sh --english` with the owner present.
