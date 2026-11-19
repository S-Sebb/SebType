# 中's model on the phone (#264, 2026-11-19)

The owner's phone (A001: CPUs 0–3 are 2.0 GHz Cortex-A55s, 4–7 Cortex-A78s), `perf.sh --chinese` at
700 ms per key with `PERF_STOP="com.google.android.apps.youtube.music com.discord"`. Each run's cores
come from its trace: the `sched.dur` of `dev.sebb.sebtype` on CPUs 0–3 against 4–7. Medians and 95th
percentiles are written "p50 / p95". The budget is 20 ms p95 for both ranking and next words.

## Where the time went

`engines/sebtype-lm/bench/zh-keys.sh` runs the model's jobs on the phone without the keyboard, with
`taskset` on the big cores, the little ones, or all of them. Measured there and in the traces, three
causes, none of them the model's size:

- **No dot product instructions.** The APK built llama.cpp for the NDK's default armv8-a. It now ships
  ggml's Android CPU variants and loads the best one the phone runs (the A001's: dot product and FP16).
  That made the model 2.5–3 times faster on both kinds of core.
- **Threads started for every decode.** Without a thread pool, llama.cpp starts and ends its threads for
  each decode, and the phone started them on the little cores. The model now keeps a pool.
- **Too many threads.** With 4 threads the model took all 4 big cores, and at every step it waited for the
  keyboard's own threads (UI, render, Rime). It runs on 2 now.

The empty field's next words, asked for while a field opens, when the phone is busiest, are now computed
once per model load. And the model is read, not mapped (as #406 does for English's): with the dot product
variant ggml repacks the weights into memory of its own, and the mapped file's pages stayed resident too.

## Results

| Build | Cores | Ranking | Next words |
|---|---|---|---|
| main (release 196, #353) | big | 21 / 32 ms | 29 / 137 ms |
| main (release 196, #353) | little | 70 / 106 ms | 73 / 114 ms |
| CPU variants, 4 threads | big (1 run) | 19 / 29 ms | 22 / 139 ms |
| CPU variants, 4 threads | little (2 runs) | 52–54 / 77–372 ms | 49–52 / 195–215 ms |
| + thread pool, 4 threads | big (3 runs) | 16–17 / 26–29 ms | 15–18 / 98–149 ms |
| + thread pool, 3 threads | little (1 run) | 38 / 61 ms | 42 / 69 ms |
| + thread pool, 2 threads | big (2 runs) | 9 / 15 ms | 11–12 / 55–58 ms |
| + empty field's next words cached, model read (this PR) | big (2 runs) | **8 / 14–16 ms** | **10–11 / 12–31 ms** |
| + empty field's next words cached, model read (this PR) | little (2 runs) | 33–36 / 53–107 ms | 42 / 52–57 ms |

In the 2-thread runs before the cache, the next words' p95 came from the empty field's next words while
the test field opened (31–65 ms); the rest took 6–13 ms. With the cache those take 0 ms after the first. In
the final build's first big-core run that first one took 90 ms (the field's first decode after the model
loaded), and one more took 31 ms, which made its p95 31 ms. The second big-core run was at 12 ms.

Memory (PSS after typing 中): 205 MB on the big cores and 234 MB on the little ones in release 181. Mapped,
with the dot product variant, 259–277 MB in the runs above; read, 251–253 MB (one little-core run: 179 MB).
The repacked weights still cost about 45 MB over release 181.

`zh-keys.sh 2 4`, 3 rounds at 700 ms between keys (ranking; next words):

| Cores | 2 threads | 4 threads |
|---|---|---|
| big (f0) | – | 5.1 / 48.9 ms; 7.3 / 12.4 ms |
| all (ff) | 6.0 / 12.7 ms; 8.8 / 9.6 ms | 5.0 / 16.0 ms; 7.1 / 21.5 ms |
| little (0f) | 24.8 / 52.5 ms; 41.4 / 43.3 ms | 35.4 / 72.0 ms; 46.5 / 66.0 ms |

On the big cores ranking meets the budget. On the little cores 2 threads also beat 4, but stay over it.
The keyboard lands there through Nothing's `nt_foreground` cpuset, which the app can't leave (#62).

What the model ranks and predicts is unchanged: the same search runs on the same weights, and threads
don't change a decode's result.
