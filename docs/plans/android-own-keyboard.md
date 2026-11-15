# Plan: SebType's own Android keyboard on core/ (#191, #190 step 3)

Status: the user's choices are recorded at the end. Nothing here is built yet.

The user's goal (2026-11-15): "I want to make sure as much of these components are our own code in consistent
form, so everything is easier to maintain and we can clean up things as much as possible while reducing final
app size and improving performance while not being limited."

Sources: Requirements #1, Decisions #2 (up to "2026-11-15, identity"), #53's kept and removed lists, #108's
inventory (how much of the app is FUTO's, 2026-11-10), #46's offline English measurements, #190's step 3
comparison, [docs/perf/2026-11-12.md](../perf/2026-11-12.md) and [2026-11-15.md](../perf/2026-11-15.md), and the
code at `bb822b88`. Sizes are from the release APK built from main on 2026-11-15 (108.8 MB, or 103.8 MiB; the
perf runs call it 103–105 MB).

## Summary

- **Build a new app and don't touch FUTO's.** It is written from scratch in Kotlin on top of `core/`, inside
  `dev.sebb.sebtype`. English uses the pristine AOSP LatinIME decoder (Apache-2.0), taken from AOSP's own repo,
  not FUTO's copy. The phone runs librime and Mozc in-process, behind the same `core/` engines the PCs use.
- **SebType's own English model ships at stage 6** (the user, 2026-11-15, Decisions 7). It passed §2's bar
  (#236) before stage 2 started, so the new keyboard never carries FUTO's model or its runner. Stage 6's
  release has no FUTO code or data. Sections below that still say "until stage 7" describe the earlier plan;
  where they differ, Decisions 7 wins.
- **The size comes from data, not UI code.** The APK is 42 % Mozc's dictionary, 28 % FUTO's English model and
  19 % Rime's data. All the UI and engine code together is under 9 %. A new UI saves about 2 MB. The memory and
  speed gains come from one keyboard window without FUTO's framework and from one JNI call per key.
- **FUTO's licence ends with stage 6.** The new app ships no FUTO code or data, so the payment screen, the
  unpaid notice and FUTO's licence notice leave with the old app. The app on the phone keeps them until then.
- **Releases are held until stage 6** (the user, 2026-11-15). The app on the phone stays as it is until the new
  keyboard replaces it.
- **About 32–47 delegate-days for stages 0–6, then 8–12 days plus training time on yanglab16 for stage 7.**

## 1. Inventory

"Lines" counts code in the tree today. Shares are of the 108.8 MB APK. The 2.8 MB `classes.dex` (2.6 %) and the
1.0 MB `resources.arsc` (0.9 %) hold every Kotlin and Java feature together. A feature's own share of them is far
below 1 %, so those rows show "code". Decisions:

- **Rewrite**: new code of SebType's own, MIT.
- **Reuse**: kept as it is, under the licence given.
- **Drop**: not carried over.

Correction to #191's "about 390k lines of Kotlin": the app has 37k lines of Kotlin, 41k of Java and 296k of C/C++.
Of the C/C++, 258k is vendored sentencepiece, ggml, absl and protobuf. By #108's blame, 58 % of the Kotlin and
Java is FUTO's, 39 % AOSP's and 3 % SebType's.

### Typing and engines

| Feature | Where now | Lines | APK share | Decision |
|---|---|---|---|---|
| Keyboard view, keys, long-press popups, key preview, touch handling | `keyboard/` (AOSP-origin, FUTO-edited) | 13,445 | code | **Rewrite**: one custom `View` drawn on a Canvas (§3) |
| Layout engine (YAML layouts, subtypes, globe list) | `v2keyboard/`, `latin/Subtypes.kt` | 4,591 | code | **Rewrite**: a small JSON layout format for the 3 layouts, symbols, the number row and later Russian |
| SebType's EN/中/日 layouts | `assets/layouts/SebType/` (Apache-2.0, adapted from FUTO's) | 212 KB of files | < 0.1 % | **Rewrite** in the new format. Same keys in the same places (#1, #10) |
| Text field handling (InputConnection, composing text, cursor tracking) | `latin/RichInputConnection.java`, `latin/inputlogic/`, wrappers | ~5,300 | code | **Rewrite**, guided by pristine AOSP's `RichInputConnection` (Apache-2.0) |
| Field kinds: password, PIN, URL, private tabs → incognito (#26, #31) | `latin/InputAttributes.java`, `IncognitoAction.kt` | 455 | code | **Rewrite**. Same rules, including "private: learned words used, nothing new learned" (2026-11-12) |
| 中文 engine glue (Rime, candidates, 简/繁, punctuation, emoji, typo re-ranker) | `engine/general/ChineseIME.kt`, `android/rime/` (RimeJni, MIT) | 871 + 1,183 | librime-jni 1.6 % | **Rewrite** onto `core/` (Rime in `core/src/rime.cpp`) |
| 日本語 engine glue (romaji, あ/ア chip, katakana candidates) | `engine/general/JapaneseIME.kt`, `android/mozc/src` (FUTO's mozc-lib: Google's BSD client with FUTO's edits) | 1,187 + ~12,200 | libmozc 1.1 % | **Rewrite** onto `core/` (Mozc in-process, §3). The 12k-line Java client goes |
| Multi-engine layer and globe switching | `engine/IMEManager.kt`, `GeneralIME.kt`, `IMEInterface.kt` | ~1,350 | code | **Rewrite**: `core/` owns languages and switching |
| Floating pre-edit (pinyin above the keys) | `latin/uix/FloatingPreEdit.kt` | 176 | code | **Rewrite** as part of the candidate bar |
| English decoder: completion and autocorrect (about 70 % of phone typos fixed, #46) | `cpp/src/dictionary`, `cpp/src/suggest` (AOSP plus 1,395 lines of FUTO's), `latin/Suggest.java` and dictionaries | 28,500 C++ + 3,900 Java | part of latinime 1.0 % | **Reuse pristine AOSP** native decoder (Apache-2.0, 29,950 lines at AOSP `127336e`) in `engines/latinime/`. **Rewrite** the glue in `core/` |
| English transformer (next-word, completion re-ranking) | `latin/xlm/`, the LanguageModel JNI, ggml (MIT), sentencepiece (Apache-2.0) | 1,265 Kotlin + 1,315 + 218k vendored | model 28.2 % + part of latinime 1.0 % | **Reuse until stage 7** (§2): the model file and FUTO's native runner only, in `engines/futo-lm/` under FUTO's licence. FUTO's Kotlin around it is **rewritten**. **Drop** at stage 7 for SebType's own model |
| English dictionary (FUTO's words, wordfreq frequencies, SCOWL-checked modern words; #40) | `res/raw/main_en.dict` (FUTO's licence + CC BY-SA 4.0) | data | 1.0 % | **Reuse until stage 7**. Then **rewrite** the build from AOSP's `en_US` wordlist (Apache-2.0) + wordfreq (CC BY-SA 4.0) + SCOWL words |
| Learned English words and personal dictionary | `UserBinaryDictionary`, `personalization/` | 511 | code | **Reuse** AOSP's user-history format through its native code. **Rewrite** the glue |
| Blocked-words filter (fixed on, #41) | `BadWords.kt`, `SuggestionBlacklist.kt` | ~150 | code | **Rewrite**: a word list applied in the English engine |
| Email domain suggestions (kept, #53 B10) | `latin/EmailDictionary.kt` | 28 | code | **Rewrite** |
| Period after a suggestion, ".py" rule (#39) | `inputlogic/` | small | code | **Rewrite**. Its four `LiveSpacingTests` become emulator checks |
| Spacebar and backspace swipes (kept, #53 B11) | `keyboard/`, `inputlogic/` | small | code | **Rewrite** in the keyboard view |
| Gesture (glide) typing | dropped 2026-11-09 (Decisions #2), library removed in #59 | dead code in `keyboard/internal/` | 0 | **Drop**. AOSP has no open gesture decoder, so bringing it back later would be SebType's own work |
| Accessibility (TalkBack) | `accessibility/` (AOSP) | 1,338 | code | **Rewrite** with `ExploreByTouchHelper`: every key and candidate gets a text label. The emulator checks find keys that way (`uiautomator dump`) |

### Bars, panels and actions

| Feature | Where now | Lines | APK share | Decision |
|---|---|---|---|---|
| Suggestion bar, mode chip (あ/ア, #38), up to 128 candidates scrolling | `UixManager.kt`, `ActionBar.kt` | 3,451 | code | **Rewrite** |
| Action bar and its buttons editor (#41) | `ActionBar.kt`, `actions/Registry.kt`, `MoreActions.kt` | ~800 | code | **Rewrite** |
| All Actions with the 简/繁 switch (#36, #53 A1) | `actions/MoreActions.kt` | 342 | code | **Rewrite** |
| Undo/Redo, Cut/Copy/Paste/Select All, Settings buttons (kept, #53) | `actions/*` | ~80 | code | **Rewrite** |
| Emoji picker, skin tones, recents (kept, #53 B1) | `actions/emoji/`, `EmojiTracker.kt`, Noto Color Emoji font, `gemoji.json` (MIT), `emoji_i18n` names (FUTO's) | 1,608 | font 1.0 %, names 0.1 % | **Rewrite** the picker. **Reuse** gemoji (MIT). Names come from Unicode CLDR annotations (Unicode licence). **Drop** the bundled font: the system's emoji font covers Android 16 |
| Clipboard history (FUTO's defaults, #26) and quick clips (#53 B8) | `actions/clipboard/`, `QuickClip.kt` | 2,109 | code | **Rewrite** |
| Inline autofill chips (kept, #53 B9) | `InlineSuggestionView.kt` | 245 | code | **Rewrite** (Android's inline suggestions API) |
| Keyboard modes: one-handed, floating, split; height (#41, #53 A2) | `resizing/`, `KeyboardSizingActions.kt` | 781 | code | **Rewrite** |
| Number row, hidden by default, Gboard's layout (#161) | layouts | small | code | **Rewrite** |
| Input-method picker (long-press 🌐, #53 A4) | Android API | small | code | **Rewrite** (one call) |
| Picnic theme, light and dark alike (#17, #87, #111) | `uix/theme/`, `ColorScheme.kt`, theme providers | ~1,600 | about 0.4 % of drawables | **Rewrite**: one fixed theme, no theme engine. **Reuse** SebType's own art and fonts (OFL) |

### Settings, data and app

| Feature | Where now | Lines | APK share | Decision |
|---|---|---|---|---|
| Settings in 6 groups, pixel frames (#41, #87); 中文 My words, emoji, punctuation; Forget learned words | `uix/settings/` (FUTO's) + `dev/sebb/sebtype/settings/` (SebType's) | 6,442 + 1,043 | code | **Rewrite** FUTO's part. **Reuse** SebType's pages where they don't depend on FUTO's settings framework |
| Setup wizard (#53 A3) | `settings/Setup.kt` | 170 | code | **Rewrite** |
| Settings export and import, PC words import (#11, #34, #44) | `SettingsExporter.kt`, `ImportResourceActivity.kt` | 1,369 | code | **Rewrite**. **Reuse** `sync/PersonalDataImport.kt` (SebType's) |
| Sync with the user's own server (#12, #14) | `dev/sebb/sebtype/sync/` | 530 | code | **Reuse** (MIT, SebType's) |
| Crash reports to the sync server (#26) | `dev/sebb/sebtype/CrashReports.kt` and app class | 176 | code | **Reuse** |
| Chinese data setup (bundled compiled data, no deploy) | `dev/sebb/sebtype/chinese/` | 524 | Rime data 19.2 % | **Reuse**. The data is unchanged, GPL-3.0, shipped as now |
| Mozc dictionary | `libmozc` data (`res/gj.dict`, stored uncompressed for mmap) | data | 41.7 % | **Reuse** unchanged (BSD-3 and its data licences). Shrinking it is out of scope (see §5) |
| Licences and credits screen | `settings/pages/credits/` | 2,176 | code | **Rewrite**: one generated list of components |
| Payment screen, thank-you screen, unpaid notice (#112) | `settings/pages/Payment.kt`, `latin/payment/`, `UixManager` notices | 814 | code | **Reuse until stage 7** (FUTO's licence), carried into the new settings with #112's note. **Drop** at stage 7 (§4) |
| FUTO's translations (ja, zh-CN strings) | `res/values-ja/`, `values-zh-rCN/` | ~2,000 strings | part of arsc | **Rewrite** SebType's own strings in 3 languages, fewer of them |
| `libc++_shared.so` workaround (#62) | build | – | 0.4 % | **Reuse** until #62 finds the real cause. The new app has its own native library to load anyway, so the workaround may not be needed (stage 6 measures it) |
| Developer mode, WordStyles, text editor pad, spell checker, memory overlay (removed, #53) | gone | 0 | 0 | **Drop** (already gone) |
| Voice input, other languages, update checks (removed, #59) | gone | 0 | 0 | **Drop**. Russian stays possible: the layout format and English engine take any alphabet and AOSP ships a Russian wordlist (Apache-2.0) |

## 2. English

**What to keep meeting.** Requirements #1 asks for "Good recommended (next-word and completion) suggestions" and
a space after a picked word. #46 found that English autocorrect fixes about 70 % of phone typos. Today all three
come from AOSP's decoder plus FUTO's tweaks plus FUTO's transformer.

**Until stage 7: FUTO's model, the least FUTO code that runs it** (the user, 2026-11-15: "Keep FUTO's app and
English model's necessary code in this release, train our own model later on yanglab16").

- `engines/latinime/`: the pristine AOSP decoder (Apache-2.0) for completion, autocorrect and learned words.
- `engines/futo-lm/`: FUTO's `ml4_q6_k.gguf` and the native code that runs it. That is FUTO's `LanguageModel`,
  `context` and model-metadata code and its JNI entry points, about 2,000 lines of FUTO's, with ggml/llama.cpp
  (MIT) and sentencepiece (Apache-2.0). It re-ranks the decoder's candidates and gives next words, as today.
- FUTO's decoder tweaks (1,395 lines in `suggest/`) come along only if the harness shows the model needs them to
  stay at today's quality. Stage 2 tries without them first.
- FUTO's Kotlin around the model (`latin/xlm/`, `LanguageModelFacilitator`) is not kept. `core/src/english.cpp`
  calls the module directly. The model still loads on the first letter typed (Decisions #2, 2026-11-11).

So the module has one interface, and SebType's own model later plugs into the same place.

**Stage 7: SebType's own model, trained on yanglab16.**

- **Data:** openly licensed English text in a typing register, such as chat (oasst1, Apache-2.0), Wikipedia
  (CC BY-SA) and subtitles or forums with permissive licences. Each source's licence is checked before training.
- **Training:** a small Llama-style transformer of FUTO's size (about 36M parameters, 8 layers), trained from
  scratch, never fine-tuned from FUTO's weights. Training-time typo noise (the #46 error mix) teaches it to
  correct as well as predict.
- **Format:** GGUF on llama.cpp (MIT), with SebType's own tokenizer and metadata. The loader in
  `engines/futo-lm/` is rewritten as `engines/sebtype-lm/`, SebType's own code (MIT).
- **Where:** training runs on yanglab16. The scripts and the training config go in the repo (`tools/english-lm/`);
  the corpus and checkpoints go in yanglab16's scratch, never in the repo.

**The quality bar** (the user, 2026-11-15: "Near today"). A host harness in the repo (`android/test/english/`)
builds the English engine for the PC and drives it through a stub, as #46 did, with no emulator. It compares
SebType's own model with today's stack (FUTO's decoder with its transformer) on the same sets:

| Metric | Set | Bar |
|---|---|---|
| Autocorrect, typo fixed at rank 1 / in the top 3 | #46's 1,000 phone typos (Palin et al. error mix) and 1,500 Wikipedia misspellings | ≥ today − 2 points |
| Correct words wrongly changed | #46's 1,000 clean words | ≤ today (1–2 %) |
| Next word in the 3 suggestions, empty prefix | held-out chat and news sentences, never in the training data | ≥ 90 % of today's rate |
| Keystroke savings with 3 suggestions (simulated taps on a suggestion once it appears) | same sentences | reported, not gated |
| Per-key time p95, engine alone | same | ≤ today |

Today's numbers are in [docs/perf/2026-11-15-english.md](../perf/2026-11-15-english.md) (stage 0, #231).
SebType's model replaces FUTO's only when every gated row passes. The same harness also checks the stage 2 stack
(AOSP decoder + FUTO's model) against today, so the rewrite itself doesn't lose quality.

**Options not taken:**

| Option | Why not |
|---|---|
| AOSP decoder with only a word-pair dictionary, no model | Weaker next-word suggestions than today; the user chose to keep the model and train SebType's own |
| Rime-based English (rime-ice's English words) | No context and no proximity correction |
| A general open model (SmolLM2-135M, Apache-2.0) | 3× FUTO's model in size and too slow per key |
| Fine-tuning FUTO's model | The result would still be FUTO's licence |

## 3. Architecture

```
dev.sebb.sebtype (Kotlin, MIT)                         libsebtype.so (C++, NDK)
┌──────────────────────────────────┐   JNI, one call   ┌────────────────────────────────────────┐
│ SebTypeIme : InputMethodService  │   per key, one    │ core/  Core: languages, switching,      │
│  Editor (InputConnection)        │ ─ state record ─▶ │        candidates, settings (sebtype.conf)│
│  KeyboardView (Canvas, one View) │                   │  ├ rime.cpp ─ librime (engines/librime) │
│  CandidateBar, ActionBar, chip   │ ◀──────────────── │  ├ mozc.cpp ─ in-process transport ──┐   │
│  Emoji / Clipboard / More panels │                   │  └ english.cpp ─ engines/latinime    │   │
│  Settings (Compose activity)     │                   │     (AOSP) + engines/futo-lm (model) │   │
│  sync/, crash/, chinese/ (reused)│                   └──────────────────────────────────────┼───┘
└──────────────────────────────────┘                      libmozc.so (Bazel, engines/mozc) ◀──┘
```

- **One library, one JNI call per key.** `libsebtype.so` links `core/`, librime and the AOSP decoder. A key
  returns one compact record: text to commit, the preedit, the first N candidates and flags. A key never crosses
  JNI more than once. Mozc stays a Bazel-built `libmozc.so` exposing `EvalCommand(bytes)`, which `core/` calls
  in-process.
- **Mozc in-process.** `core/src/mozc.cpp` today talks to `mozc_server` over IPC. Split it into the protocol
  code, which is shared, and a transport: IPC on the PCs, a direct call into Mozc's `SessionHandler` on Android.
  The protobuf commands are identical, so the key translation, あ/ア and the candidate handling become one
  code path on all three platforms.
- **Rime on Android.** `core/src/rime.cpp` gets a "prebuilt data" mode. It never deploys and uses the compiled
  data that `chinese/RimeIceSetup.kt` unpacks (Decisions #2, #45: no deploy on the phone).
- **English in `core/`.** A new `Engine` for `Lang::English` on Android only. The PCs keep plain English
  (Decisions #2).
- **What `core/` gains for touch:**
  - `cycleLanguage()` for 🌐, which goes through every language in order (#1). Win+Space stays the PC toggle.
  - A candidate list that is not paged (the phone scrolls up to 128). This reuses `Engine::candidateAt`.
  - Keys sent as characters: a tap of "a" is keysym `a`.
  - The phone's field kinds: password and private disable learning.
  - What happens to typed text when the language changes. The PCs commit it (Win+Space leaves 中文 with the
    preedit typed out); the phone drops it (the user, 2026-11-15: "Throw it away"). `Settings` gets
    `commitOnSwitch` (true on the PCs, false on Android), so the rule stays in `core/` instead of in a frontend.

  `core/test/core_test.cpp` covers each of these, including both values of `commitOnSwitch`.
- **Threads.** Typing runs on the main thread, as today: each engine takes about 2 ms per key. Next-word
  suggestions are computed on one worker thread and posted back, so a key never waits for them.
- **Settings shared with the PCs.** `core::Settings` grows from `[Languages] Order=` to everything both
  sides set:
  - which languages are on and their order (the PCs' order is Win+Space's home; the phone's is the 🌐 cycle);
  - 简/繁;
  - 中文 full-width punctuation;
  - emoji in 中文 candidates;
  - learning on or off.

  The phone keeps them in `sebtype.conf` in its files dir and its settings screens read and write them through
  JNI. The PC Configurator goes through the same keys instead of editing Rime's `*.custom.yaml` itself.
  Phone-only options stay in Kotlin DataStore: the number row, height and modes, clipboard, sync login.
- **UI toolkit.** The keyboard window uses plain Views, not Compose: cold open and PSS matter there (cold open is
  456 ms p50 today). The settings activity keeps Compose for the pixel-frame look (#87), so Compose loads only
  when settings open.
- **Package.** The new code goes under `android/app/src/main/java/dev/sebb/sebtype/`, the only Kotlin package
  left after stage 6. Gradle modules: `:app` and `:native` (CMake for `core/`, librime, latinime and the model
  module; the Bazel task for Mozc). `:rime` and `:mozc` go.

### Build

From now on SebType's heavy agent builds (Gradle with the NDK, Mozc's Bazel build, librime, and the model
training of stage 7) run on yanglab16, which a separate setup task prepares. nobara-pc keeps the emulator runs
(one emulator at a time) and installs the APKs yanglab16 builds. Each stage's PRs build there and their tests run
on nobara-pc's emulator. ggml and sentencepiece stay in `:native` with FUTO's model until stage 7.

## 4. Licence

FUTO's licence (LICENSE.md) applies to any copy that contains FUTO's code or data. It requires the payment
functionality to stay and FUTO's notices to be kept. Once a release contains no FUTO code or data, neither
applies to that release. Rules for the rewrite (#108):

- Write each part from a behaviour description: the requirements, the decisions and the emulator checks. Don't
  read or translate FUTO's file while writing its replacement. Ideas and behaviour are free; copied expression
  is not.
- Reuse AOSP code only from AOSP's own repo (`~/src/sebtype-upstream/aosp-latinime`, `127336e`), never from
  FUTO's tree. FUTO's edits to AOSP files are FUTO's.
- SebType's 2,847 lines inside FUTO's files count as FUTO-derived, so they are rewritten too. Their behaviour is
  SebType's spec.
- FUTO's code that stays is copied as it is into clearly marked places, never mixed into SebType's files.

**FUTO's code and data in the stage 6 release** (the first release of the new keyboard):

| What | Where | Why it stays |
|---|---|---|
| FUTO's English model `ml4_q6_k.gguf` | `engines/futo-lm/` | the user's choice, until stage 7 |
| FUTO's native code that runs it (`LanguageModel`, `context`, model metadata, JNI), about 2,000 lines | `engines/futo-lm/` | needed by the model |
| FUTO's decoder tweaks in `suggest/`, 1,395 lines, only if the harness shows the model needs them | `engines/futo-lm/` | needed by the model |
| `main_en.dict`, FUTO's English word list with wordfreq frequencies | `engines/futo-lm/` | rebuilt from AOSP's list at stage 7 |
| The payment screen, the thank-you screen and the unpaid notice, with #112's note | `android/app/src/main/java/org/futo/payment/` | FUTO's licence: payment functionality may not be removed |
| `LICENSE.md`, FUTO's NOTICE section and the one-sentence modification notice (Decisions #2, 2026-11-15) | repo and the app's licence screen | FUTO's licence |

Everything else of FUTO's goes at stage 6:

- `android/app/src/main/java/org/futo/**` other than the payment screens;
- the rest of `android/app/src/main/cpp`;
- `android/mozc/src` (FUTO's mozc-lib);
- FUTO's Gradle files, `android/tools/` scripts and `.github/ISSUE_TEMPLATE/`;
- `emoji_i18n.jsondlgz` and FUTO's translations;
- FUTO's layouts (Apache-2.0, but the new format replaces them).

The README keeps FUTO Keyboard in its components list, as its English model.

**At stage 7** SebType's own model and dictionary replace the last FUTO files. In that release:

- the payment screen, thank-you screen and unpaid notice go;
- `LICENSE.md` and FUTO's NOTICE section leave the shipped app and the repo's current tree (git history keeps
  them);
- the README drops FUTO Keyboard from its components;
- `android/LICENSE` and NOTICE list Apache-2.0 for `engines/latinime/`, MIT for llama.cpp/ggml, BSD-3 for Mozc
  and librime, LGPL-2.1 for `core/src/rime.cpp`, GPL-3.0 for the Chinese data, and CC BY-SA 4.0 for SebType's
  English model, crediting its training sources (`tools/english-lm/SOURCES.md`; Decisions 6).

## 5. Size and performance targets

Today's numbers are from the phone run (Nothing A001, 2026-11-12). The budgets are provisional (Decisions #2,
2026-11-11), so these are targets to measure against, not gates. The stage 6 column keeps FUTO's model. The
stage 7 column assumes SebType's model is no bigger than FUTO's (36M parameters, about 31 MB).

| Metric | Today | Stage 6 (FUTO's model kept) | Stage 7 (own model) |
|---|---|---|---|
| APK | 108.8 MB (103.8 MiB) | ≤ 106 MB (emoji font −1.1, dex −1.3, native −0.5) | ≤ 106 MB |
| `classes.dex` | 2.8 MB | ≤ 1.5 MB | ≤ 1.5 MB |
| Native code | 4.6 MB | ≤ 4.5 MB | ≤ 4.5 MB |
| PSS idle, fresh / after use | 74 / 109 MB | ≤ 60 / 85 MB | same |
| PSS after typing EN (model loaded) | 204 MB | ≤ 180 MB | ≤ 180 MB |
| PSS after 中 / 日 alone | 133 / 146 MB | ≤ 120 / 135 MB | same |
| PSS with all three | 267 MB | ≤ 240 MB | ≤ 240 MB |
| Key handling p95, EN / 中 / 日 | 7 / 6 / 4 ms | ≤ 5 ms each | same |
| Key → text p95, EN / 日 | 22 / 41 ms | ≤ 20 / 35 ms | same |
| Key → candidates p95, EN / 中 / 日 | 78 / 65 / 52 ms | ≤ 70 / 50 / 45 ms | EN ≤ 70 ms |
| Warm / cold open p50 | 68 / 456 ms | ≤ 60 / 300 ms | same |
| Late frames at 10 keys/s, empty field | 1 in 701 | ≤ 1 in 700 | same |

Most of the memory saving comes from the keyboard window: plain Views instead of Compose and FUTO's UI framework,
and no FUTO settings, theme or action classes loaded while typing. The model's own memory (about 70 MB once
loaded) stays until stage 7, and SebType's model is expected to need about the same.

Not in this plan: Mozc's 45 MB dictionary is the biggest file in the APK. A smaller Mozc data set (for example
without the zip-code dictionary) would be its own issue. Decisions #2 (2026-11-10) says nothing is compressed for
size, and that rule stays.

## 6. Stages

Each stage is one or more PRs. Releases are held until stage 6 (the user, 2026-11-15), so stages 0–5 merge to
main without a release, and main's app keeps passing `emulator.sh` after every merge. Tests are
`android/test/emulator.sh` checks (`SEBTYPE_CHECKS=` for the stage's own), `core_test`, and the English harness.
Builds run on yanglab16 (§3, Build). A delegate-day is one delegate's day of tested work, about 1,000–1,500 lines
(#108's measure).

| # | Stage | What main's app does after it | Tests | Effort |
|---|---|---|---|---|
| 0 | **English harness and baseline.** Host build of today's decoder plus transformer and of the pristine AOSP decoder; the sets from #46 plus next-word sentences; a baseline table in `docs/perf/` | unchanged | the harness itself; numbers reproducible across two runs | 2–3 days |
| 1 | **`core/` on Android (#190 step 3).** `:native` module, Mozc in-process transport, Rime prebuilt mode, `cycleLanguage`, `commitOnSwitch`, the unpaged list, settings in `sebtype.conf`. FUTO's `ChineseIME` and `JapaneseIME` call `core/` through JNI; `android/mozc/src` and `android/rime` go | the same app; 中 and 日 run through `core/` | `core_test` (new touch paths, both `commitOnSwitch` values); `emulator.sh` `chinese-run` (ranh, lh-in-bar, learn-*, zh-hant-*, ja-*), `settings-zh-*`, `incognito-zh`, `incognito-ja`; Linux and Windows `core_test` still pass | 5–7 days |
| 2 | **English engine.** `engines/latinime/` (pristine AOSP), `engines/sebtype-lm/` (SebType's own model, #236; Decisions 7), the English dictionary rebuilt from AOSP's `en_US` list, `core/src/english.cpp`, learned words, blocked words, email domains | unchanged (still FUTO's English) | the harness: the new stack is near today (§2's bar); `core_test` for the English engine | 4–6 days |
| 3 | **New keyboard, typing core.** `SebTypeIme`, `Editor`, `KeyboardView` with the 3 layouts, symbols and number row, 🌐 cycle and long-press picker, candidate bar with chip and 简/繁 menu, field kinds and incognito, Picnic look, accessibility labels. Built as a test-only `dev.sebb.sebtype.next` package beside the app | unchanged (new keyboard in the test package) | `chinese.py` and `settings.py` gain a `SEBTYPE_PACKAGE` switch; run `chinese-run`, `incognito-*`, the four #39 period checks, `uniform-layouts`, and a new check that pinyin is dropped on 🌐; screenshots next to today's for the user | 8–12 days |
| 4 | **New keyboard, the rest.** Action bar and editor, All Actions, emoji picker (CLDR names), clipboard and quick clips, inline autofill, keyboard modes and height, spacebar and backspace swipes, haptics and key sounds | unchanged (test package) | new checks: `emoji-picks`, `clipboard-paste`, `quick-clip`, `modes-*`, `swipe-*`; screenshots for the user | 6–9 days |
| 5 | **Settings and data.** Compose settings in 6 groups with pixel frames, setup wizard, export and import, PC words, sync and crash reports, credits, FUTO's payment screens with #112's note; **migration** of an installed FUTO-based SebType's data on update (DataStore keys, learned English words, Rime userdb and Mozc profile kept in place) | unchanged (test package) | `settings-run` in full (including `settings-payment-note`), `sync-*`, `settings-backup-*`, a new `update-from-futo-app` check (learned words in all 3 languages survive) | 5–7 days |
| 6 | **Switch and release.** The new app becomes `dev.sebb.sebtype`; all of FUTO's code and data goes, with the payment screens and FUTO's notices (Decisions 7); licence files and README updated; perf run on the phone (#54 style); **the first release since the hold** | **the new app, released** | full `emulator.sh`, `typing.sh`, `android/perf/perf.sh`, the harness; `trimmed` gains a check that no `org.futo` class or FUTO file is left; phone perf run including English | 2–3 days |
| 7 | **SebType's own English model** (training done in #236; the swap moved into stages 2 and 6 by Decisions 7, so what's left here is optional model upgrades). Corpus and training scripts in `tools/english-lm/`, training on yanglab16, `engines/sebtype-lm/` loader, dictionary rebuilt from AOSP's `en_US`; swap in once the harness passes §2's bar; then FUTO's last files, the payment screens and FUTO's notices go | the app with no FUTO code, released | the harness against §2's bar; `emulator.sh` English checks (`en-model-waits-for-letter`, `incognito-en`, the #39 checks); `trimmed` checks that no `org.futo` class or FUTO file is left; phone perf run | 8–12 days + GPU time |

Stages 0–6 take about 32–47 delegate-days. Stages 2 and 3 can run in parallel after stage 1. Stage 7 can start
its corpus and training work on yanglab16 any time after stage 0, since only the swap depends on stage 6.

## 7. Risks

| Risk | Effect | How the plan handles it |
|---|---|---|
| SebType's own model doesn't reach "near today" | FUTO's licence and payment screen stay longer | Stage 7 swaps only when §2's bar passes; until then FUTO's model keeps working. Training can be repeated on yanglab16 with more data or a larger model |
| The new English stack (AOSP decoder + FUTO's model, without FUTO's Kotlin) is worse than today | Weaker English from stage 6 | Stage 2's harness compares it with today; FUTO's decoder tweaks come along if needed |
| Text-field quirks FUTO fixed (Chrome, WebView, Termux, apps that reset composing text) come back | Lost or doubled characters in some apps | `Editor` is guided by pristine AOSP's `RichInputConnection`; stage 3 adds checks typing into Chrome and a WebView on the emulator |
| Mozc's in-process session behaves differently from FUTO's client (focus, timeouts, prediction) | 日本語 regressions | Stage 1 lands it inside today's app, so the existing `ja-*` checks catch it before any UI change |
| Data loss on the update at stage 6 | Learned words gone | Stage 5's `update-from-futo-app` check; Rime and Mozc keep their files where they are |
| Clean-room discipline slips: a delegate translates a FUTO file | The release is still FUTO-derived after stage 7 | Briefs forbid opening FUTO's file for the part being written; the reviewer checks new files against FUTO's with a similarity scan before stages 6 and 7 |
| Weeks without a release (held until stage 6) | Fixes and improvements wait; a bug found on the phone can't be shipped | The user chose this. A blocking bug can still be fixed on a branch from the last release tag if the user asks |
| Accessibility and long-tail behaviours nobody listed (key repeat, cursor-control edge cases, landscape) | Small regressions | Stage 3–4 checklist from today's app; the user tries the test package before stage 6 |
| yanglab16 isn't set up or reachable (Zscaler) | Builds and training stall | Its setup is a separate task; until it is ready, builds stay on nobara-pc under the build lock |

## Decisions (the user, 2026-11-15)

1. **English prediction** (replaced by 7)**:** "Keep FUTO's app and English model's necessary code in this release, train our own
   model later on yanglab16 where there are tons of GPUs and RAM and CPUs." The new keyboard keeps FUTO's model
   and only the code it needs (§2, §4); SebType's own model replaces it at stage 7.
2. **Quality bar:** "Near today": typo fixes within 2 points, no more correct words wrongly changed, next word in
   the top 3 at least 90 % as often. It gates the swap to SebType's own model (§2).
3. **Releases:** "Hold until stage 6". No releases during the rewrite (§6).
4. **Pinyin when leaving 中文 on the phone:** "Throw it away", as the phone does today. The PCs keep committing it,
   so `core/` gets a per-platform setting, `commitOnSwitch` (§3).
5. **Builds:** SebType's heavy agent builds run on yanglab16 from now on (§3, Build).
6. **Licence of SebType's English model:** "CC BY-SA 4.0". Part of its training text is share-alike (Wikipedia,
   Dolly), so the model file ships under CC BY-SA 4.0 with every source credited in NOTICE, like the English
   dictionary's frequencies. The code that trains and runs it stays MIT (§4).
7. **Own English model in the first release:** "Ship our own model". SebType's model passed §2's bar (#236) before
   stage 2, so stage 2 builds the English engine on it and the stage 6 release ships it, with no FUTO code or
   data. This replaces Decision 1's "Keep FUTO's ... English model's necessary code in this release". Before
   release, the model is re-tested on the phone and against the "correct words wrongly changed" bar, which it
   meets with no margin.
