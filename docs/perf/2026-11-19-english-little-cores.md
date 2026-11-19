# English on the phone's little cores (#406, 2026-11-19)

The owner's phone is an A001: CPUs 0–3 are 2.0 GHz Cortex-A55s and 4–7 are Cortex-A78s. Nothing's
`nt_foreground` cpuset puts the keyboard on the little cores in some of its starts, and the app can't
leave it (#62). Before this change, English there missed #359's target:
- fast typing waited at every space;
- next words took 190 ms, against 42 ms on the big cores.

The phone runs are `perf.sh --english` with
`PERF_STOP="com.google.android.apps.youtube.music com.discord"`. Each run's cores come from its trace:
the `sched.dur` of `dev.sebb.sebtype` on CPUs 0–3 against 4–7. Medians and 95th percentiles are written
"p50 / p95".

## Where the time went

The model alone ran on the phone without the keyboard, pinned with `taskset`. Each key scored 7 words,
as the keyboard does, and each space asked for the next words. Medians:

| llama.cpp built for | Model | Little: ranking / next words | Big: ranking / next words |
|---|---|---|---|
| armv8-a (the NDK's default) | Q6_K | 141 / 198 ms | 26 / 41 ms |
| armv8-a | Q8_0 | 95 / 147 ms | 16 / 27 ms |
| armv8.2-a with dot product and FP16 | Q6_K | 69 / 75 ms | 15 / 18 ms |
| armv8.2-a with dot product and FP16 | Q8_0 | 50 / 51 ms | 11 / 11 ms |

- **No dot product instructions.** This made the model 2.5–3 times slower. #414 (#264) now ships ggml's
  Android CPU variants and loads the best one the phone runs.
- **Q6_K.** It has no dot product kernel as fast as Q8_0's. The model is now Q8_0, exported from the same
  r2 checkpoint. It is 38.3 MB, against 29.7 MB.
- Each row of logits was normalised once per token read from it, and is now normalised once. This gives
  the same numbers 3–5 % faster.

## What the model suggests

`android/test/english/run.sh` measured core/'s English with each model; both pass the bar:

| Measure | Q6_K | Q8_0 |
|---|---|---|
| Phone typos: fixed by a space | 84.7 % | 84.7 % |
| Phone typos: first / in the top 3 | 91.7 / 95.3 % | 91.3 / 95.2 % |
| Typos in text messages: fixed by a space | 74.9 % | 74.5 % |
| Typos in text messages: first / in the top 3 | 84.8 / 91.5 % | 84.8 / 91.5 % |
| Wikipedia misspellings: fixed | 55.0 % | 54.7 % |
| Wikipedia misspellings: first / in the top 3 | 83.3 / 88.5 % | 83.3 / 88.4 % |
| Clean words wrongly changed | 0.3 % | 0.3 % |
| Next word in the top 3: chat / news / texts | 41.7 / 43.7 / 29.1 % | 41.7 / 44.2 / 28.9 % |
| Keystrokes saved | 42.3 % | 42.4 % |

Every difference is 0.5 points or less, in both directions. At this size that is 4 or 5 of 1,000 words.
`decide()`'s weights were tuned on Q6_K and weren't tuned again.

## Memory

With the dot product kernels, ggml repacks the weights into memory of its own. The mapped model
file's pages stayed resident as well, so the weights were held twice. The model is now read, not
mapped (#414 did the same for 中). The table gives the model alone on the phone, VmRSS at the end:

| llama.cpp built for | Q6_K, mapped | Q6_K, read | Q8_0, mapped | Q8_0, read |
|---|---|---|---|---|
| armv8-a | 58 MB | 58 MB | 66 MB | 66 MB |
| dot product | 86 MB | 64 MB | 101 MB | 75 MB |

Reading instead of mapping changed neither speed. The emulator's `en-model-waits-for-letter` check
looked for the model in the keyboard's mappings. It now looks for the model's size in the bytes the
keyboard has read.

## Results on the phone

Release builds 0.1.30-sebtype.208 of #414's head ("#414") and of this change on it ("this"), and
"main" from main before #414 (f26bc69ae6), which ran on the big cores.

| Run | Cores, little / big | EN ranking | EN next words | Fast: spaces that waited | Long field: next words; spaces that waited, wait | PSS after typing EN |
|---|---|---|---|---|---|---|
| main | 0.7 / 6.9 s | 20 / 45 ms | 42 / 56 ms | 0 of 18 | 43 / 251 ms; 1, 80 ms | 152 MB |
| #414 | 15.4 / 0.2 s | 57 / 88 ms | 77 / 100 ms | 3 of 18, 40 / 47 ms | 88 / 312 ms; 6, 66 / 236 ms | 186 MB |
| this, stack-1 | 12.3 / 0.1 s | 38 / 56 ms | 46 / 63 ms | 0 of 18 | 54 / 205 ms; 2, 21 / 41 ms | 171 MB |
| this, stack-4 | 12.4 / 0.1 s | 38 / 56 ms | 48 / 62 ms | 0 of 18 | 56 / 197 ms; 2, 19 / 29 ms | 168 MB |
| this, stack-3 | 0.6 / 5.5 s | 12 / 17 ms | 15 / 19 ms | 0 of 18 | 16 / 50 ms; 0 | 165 MB |

The little-core runs before #414 are #353's: ranking 101 / 205 ms, next words 190 / 230 ms, every space
waiting in fast typing (152 / 281 ms), and the long field's ranking late or skipped for 14 of 18
spaces.

On the little cores no space waits in fast typing now. In the long field, all 18 spaces are decided by
the model, and 2 waited about 20 ms. Next words take 46–48 ms, against the 42 ms target. On the big
cores everything is faster than before.

Memory after typing English is 13–19 MB over main before #414, and 15–21 MB under #414 alone:
- the Q8_0 weights add 8 MB;
- the dot product kernels' repacked copies add the rest.

Key → text was unchanged at 16 / 21–22 ms, and every key was typed.

Two of the four runs of this build failed perf.sh's `zh-deploy` check: one log line was missing from
logcat in one run, and the whole log in another. That second run also had 23 of 44 characters in its
first EN set. Its other sets typed every key, and the build's other two runs passed every check. This
change doesn't touch the Chinese setup.
