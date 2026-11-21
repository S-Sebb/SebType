# Installing SebType

SebType runs on an Android phone ([Android](#android)), on Linux ([Linux](#linux)) and on Windows
([Windows](#windows)). Each one works on its own; [sync](../sync-server/README.md) joins them.

## Android

SebType is published as GitHub releases of `S-Sebb/sebtype`, one arm64-v8a APK per release,
`SebType-<version>-arm64-v8a.apk`. Install the latest one; SebType updates itself from then on
([Updates](#updates)). Obtainium works too, but isn't needed. SebType's
application id is `dev.sebb.sebtype`, so it installs next to other keyboards such as Gboard. An update
from a release before 2026-11, when the app was based on FUTO Keyboard (#262), keeps SebType turned on and
picked, with your words, settings and clipboard.

### Install with Obtainium

1. Obtainium → Add App.
2. App source URL: `https://github.com/S-Sebb/sebtype`
3. Leave the defaults (latest release, APK asset), tap Add, then Install.

Obtainium checks for new releases like for any other app.

### Updates

SebType checks GitHub's latest release once a day, and from Settings › About › Check for updates (#422).
The request is all it sends: no login, no device ID, not even the phone's model. A newer release shows
on the settings' home screen, on About and as a notification (Android 13 and later ask whether SebType may
notify, the first time About shows the switch). Tapping it downloads the release's APK and opens Android's
install prompt; the first time, Android asks to allow installs from SebType. Android installs only an
APK signed with SebType's key. The switch "Check for updates automatically" on About turns the daily
check off. Releases from before 0.1.0 (`v0.1.30-sebtype.N`) are never offered as newer.

### Turn it on

Open SebType from the launcher and follow its setup (enable the keyboard, then pick it). Switch
between SebType and your other keyboards with the navigation-bar keyboard icon.

## Linux

For KDE Plasma on Wayland, on Fedora or Nobara. Download `SebType-setup-<version>-linux-x86_64.sh` from
the [latest release](https://github.com/S-Sebb/SebType/releases/latest) (no sign-in needed) and run:

```
sh SebType-setup-<version>-linux-x86_64.sh
```

It opens a graphical setup wizard (use `--no-gui` or run headless for terminal mode), installs the `sebtype`
package (SebType's Fcitx5 add-on over Fedora's Fcitx5, with Mozc's server), SebType's librime, SebType's
Chinese data and the SebType Configurator, sets the session up so that SebType types in every app, XWayland
ones included, and lets you optionally sign in to Account Sync. It asks once for administrator approval to
install the packages, changes only your account's settings, and backs up every file it replaces. Log out and
back in (or toggle Virtual Keyboard off and on in KDE System Settings) once it is done. Running a newer
installer upgrades SebType and keeps what it learned. Installing from a checkout (`pc/linux/setup-ime.sh`),
each step, and how to undo it: [pc/linux/README.md](../pc/linux/README.md).

## Windows

Download `SebType-setup-<version>.exe` from the [latest release](https://github.com/S-Sebb/SebType/releases/latest)
(no sign-in needed). Run it, pick the languages (English, 中文, 日本語), confirm Windows' admin prompt, and
optionally sign in to Account Sync. Running a newer installer upgrades SebType and keeps what it learned;
uninstall it from Windows' Apps. What it changes, and the silent install:
[pc/windows/README.md](../pc/windows/README.md).

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

It publishes SebType `<version>` from the repo's `VERSION` file, the one version of the phone app, Windows
setup and Linux installer: a release tagged `v<version>` with one installer per platform: the signed arm64
APK, built under the shared build lock (`/tmp/agent-locks/sebtype/build.lock`), `SebType-setup-<version>.exe`
from the [Windows setup workflow](https://github.com/S-Sebb/SebType/actions/workflows/windows-setup.yml), and
`SebType-setup-<version>-linux-x86_64.sh` from the
[Linux RPM workflow](https://github.com/S-Sebb/SebType/actions/workflows/linux-rpm.yml), both built from the
same commit. Each release bumps `VERSION` in its own PR, whose merge runs those workflows on main; the
script refuses a tag that already exists, and stops before publishing anything when that commit has no
successful run or its `sebtype-setup` / `sebtype-linux-setup` artifact has expired (**Run workflow** on
`main` builds it again).
`android/release.sh --dry-run` checks the tag and downloads the PC installers without building or publishing, and
`android/test/release.sh` tests the script without publishing. The APK's version code is the number of
commits on main, so every release from main upgrades the previous one, the `0.1.30-sebtype.<n>` releases
from when the app was based on FUTO Keyboard included. Needs JDK 21 in `~/.local/share/jdks/` (or
`JAVA_HOME_21`), the Android SDK with NDK 28.2 in `~/Android/Sdk` (or `ANDROID_HOME`) and a logged-in `gh`.
