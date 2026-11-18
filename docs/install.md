# Installing SebType

SebType runs on an Android phone ([Android](#android)), on Linux ([Linux](#linux)) and on Windows
([Windows](#windows)). Each one works on its own; [sync](../sync-server/README.md) joins them.

## Android

SebType is published as GitHub releases of `S-Sebb/sebtype`, one arm64-v8a APK per release.
Obtainium installs and updates it straight from those releases; no token is needed. SebType's
application id is `dev.sebb.sebtype`, so it installs next to other keyboards such as Gboard. An update
from a release before 2026-11, when the app was based on FUTO Keyboard (#262), keeps SebType turned on and
picked, with your words, settings and clipboard.

### Install with Obtainium

1. Obtainium → Add App.
2. App source URL: `https://github.com/S-Sebb/sebtype`
3. Leave the defaults (latest release, APK asset), tap Add, then Install.

Obtainium checks for new releases like for any other app.

### Turn it on

Open SebType from the launcher and follow its setup (enable the keyboard, then pick it). Switch
between SebType and your other keyboards with the navigation-bar keyboard icon.

## Linux

For KDE Plasma on Wayland, on Fedora or Nobara. From a checkout of this repository:

```
pc/linux/setup-ime.sh --dry-run   # show what it would change
pc/linux/setup-ime.sh             # set it up; safe to run again
```

It builds and installs the `sebtype` package (SebType's Fcitx5 add-on over Fedora's Fcitx5, with Mozc's
server), SebType's Chinese data and the SebType Configurator, and sets the session up so that SebType
types in every app, XWayland ones included. It changes only your account's settings, asks before it
uses sudo to install packages, and backs up every file it replaces. Log in again once it is done.
Each step, and how to undo it: [pc/linux/README.md](../pc/linux/README.md).

## Windows

SebType's installer, `SebType-setup-<version>.exe`, is built by the
[Windows setup workflow](https://github.com/S-Sebb/SebType/actions/workflows/windows-setup.yml): open
its latest successful run on `main` and download the `sebtype-setup` artifact (GitHub asks you to sign
in). Run it, pick the languages (English, 中文, 日本語) and confirm Windows' admin prompt. Running a newer
installer upgrades SebType and keeps what it learned; uninstall it from Windows' Apps. What it changes,
and the silent install: [pc/windows/README.md](../pc/windows/README.md).

## Signing key

Releases are signed with SebType's own key, which never goes into the repo or a release.
`android/build.sh` reads it from `~/.config/sebtype/` (or `SEBTYPE_KEY_DIR`): `sebtype-release.jks`
(alias `sebtype`) and its password in `keystore.password`. Keep an offline backup of that folder.
Android only accepts updates signed with the same key: losing it means uninstalling SebType and
reinstalling it, which wipes its learned words and settings.

Gradle builds a release unsigned, never with Android's public test key (`android/app/shared.keystore`).
`android/build.sh release` then signs it with `apksigner` on this PC, the same way whether it was built
here or on the build host, so a release is the same file from either.

## Publishing a release

From a clean checkout of `origin/main`:

```
android/release.sh
```

It builds the signed arm64 release APK under the shared build lock
(`/tmp/agent-locks/sebtype/build.lock`) and runs `gh release create` with tag
`v<android/upstream-version>-sebtype.<n>`, where `<n>` is the number of commits on main (also the version code,
so every release from main upgrades the previous one). Needs JDK 21 in `~/.local/share/jdks/` (or
`JAVA_HOME_21`), the Android SDK with NDK 28.2 in `~/Android/Sdk` (or `ANDROID_HOME`)
and a logged-in `gh`.
