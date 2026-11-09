<img src="assets/icon.png" width="96" height="96" alt="">

# SebType

SebType is a **modified version of [FUTO Keyboard](https://github.com/futo-org/android-keyboard)**: a
personal Android keyboard for Chinese (pinyin), Japanese (romaji) and English, with one layout for all
three. It is not made, endorsed or supported by FUTO; please don't report SebType problems to FUTO.

**Licence:** SebType is FUTO's code with changes, under FUTO's [FUTO Source First License 1.1](LICENSE.md)
(see also [NOTICE](NOTICE)). That licence makes it source-available, not open source: anyone may use it, but it may
be modified only for non-commercial purposes and shared only free of charge and non-commercially, with
FUTO's payment features and notices left in. SebType's changes are under the same licence.

- What it must do: [Requirements (#1)](https://github.com/S-Sebb/sebtype/issues/1)
- Settled choices: [Decisions (#2)](https://github.com/S-Sebb/sebtype/issues/2)
- Install on a phone (Obtainium, GitHub releases): [docs/install.md](docs/install.md)
- Build and publish a release: `sebtype/release.sh` (see [docs/install.md](docs/install.md))

SebType's application id is `dev.sebb.sebtype`, so it installs next to stock FUTO Keyboard.
FUTO's own README follows unchanged.

---

# FUTO Keyboard

The goal is to make a good modern keyboard that stays offline and doesn't spy on you. This keyboard is a fork of [LatinIME, The Android Open-Source Keyboard](https://android.googlesource.com/platform/packages/inputmethods/LatinIME), with significant changes made to it.

Check out the [FUTO Keyboard website](https://keyboard.futo.tech/) for downloads and more information.

The code is licensed under the [FUTO Source First License 1.1](LICENSE.md).

## Issue tracking and contributing

Please check the GitHub repository to report issues: [https://github.com/futo-org/android-keyboard/](https://github.com/futo-org/android-keyboard/)

The source code is hosted on our [internal GitLab](https://gitlab.futo.org/keyboard/latinime) and mirrored to [GitHub](https://github.com/futo-org/android-keyboard/). As registration is closed on our internal GitLab, we use GitHub instead for issues and pull requests.

Due to custom license, pull requests to this repository require signing a [CLA](https://cla.futo.org/) which you can do after opening a PR. Contributions to the [layouts repo](https://github.com/futo-org/futo-keyboard-layouts) don't require CLA as they're Apache-2.0

If you want to help translate the app, please do so via our Pontoon instance: https://i18n-keyboard.futo.org/

## Layouts

If you want to contribute layouts, check out the [layouts repo](https://github.com/futo-org/futo-keyboard-layouts).

## Building

When cloning the repository, you must perform a recursive clone to fetch all dependencies:
```
git clone --recursive https://gitlab.futo.org/keyboard/latinime.git
```

If you forgot to specify recursive clone, use this to fetch submodules:
```
git submodule update --init --recursive
```

You can then open the project in Android Studio and build it that way, or use gradle commands:
```
./gradlew assembleUnstableDebug
./gradlew assembleStableRelease
```

## APK signing

For official FUTO Keyboard versions, you can verify the APK's signing key fingerprint for integrity.

```
Signing key fingerprint for all versions except Google Play:

MD5: 3A:BB:71:C6:BB:E4:92:27:B1:E3:5D:81:01:48:6A:B0
SHA1: 5D:15:B3:6E:C9:6A:96:28:41:09:DD:62:93:0D:9C:39:9F:5F:06:43
SHA-256: 74:3F:AD:58:64:AB:C4:26:50:0B:2D:C2:C4:7C:8A:D3:24:CB:CD:16:03:3F:80:16:99:48:41:35:63:74:F9:95

```
