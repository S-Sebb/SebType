# rime-android

The Rime Android library SebType uses for Chinese: a drop-in replacement for FUTO's
`libs/rime-release.aar` (same Kotlin API, `icu.astronot233.rime.*`) with librime-lua
and librime-octagram built in, so rime-ice's Lua features work (dates, calculator,
pinned candidates, the Caps fix).

It is [RimeJni](https://gitlab.futo.org/keyboard/RimeJni) (librime 1.16.1) at the commit
pinned in `versions.sh`, plus `patches/`: pinned librime-lua, Lua 5.4.7,
librime-octagram and librime-predict sources, an ABI switch (arm64-v8a by default) and
NDK 28.2.

| Script | What it does |
|---|---|
| `build.sh` | Builds `out/rime-android-<version>-arm64-v8a.aar` (`RIME_ABIS=x86_64` for the emulator). Takes the build lock. |
| `fetch-aar.sh [DEST]` | Downloads the released aar and checks it against `rime-android.sha256`. For the app build. |
| `smoke-test.sh` | Checks symbols, Kotlin API and size of the arm64 aar, then deploys rime-ice on a running emulator and types `ranh`, `rq`, `hm`. Results in `/tmp/sebtype/7-smoke/results.txt`. |

The aar is not committed. A release is the GitHub release `rime-android-<version>` with
the arm64 aar as its asset; bump `RIME_ANDROID_VERSION` and `rime-android.sha256` with it:

```sh
./build.sh
gh release create rime-android-<version> out/rime-android-<version>-arm64-v8a.aar
sha256sum out/rime-android-<version>-arm64-v8a.aar | sed 's#out/##' > rime-android.sha256
```
