# Installing SebType

SebType is published as GitHub releases of `S-Sebb/sebtype`, one arm64-v8a APK per release.
Obtainium installs and updates it straight from those releases; no token is needed. SebType's
application id is `dev.sebb.sebtype`, so it installs next to stock FUTO Keyboard and Gboard.

SebType is a modified FUTO Keyboard under the FUTO Source First License (see the README); it is not
made or supported by FUTO.

## Install with Obtainium

1. Obtainium → Add App.
2. App source URL: `https://github.com/S-Sebb/sebtype`
3. Leave the defaults (latest release, APK asset), tap Add, then Install.

Obtainium checks for new releases like for any other app.

## Turn it on

Open SebType from the launcher and follow its setup (enable the keyboard, then pick it). Switch
between SebType, FUTO and Gboard with the navigation-bar keyboard icon.

## Signing key

Releases are signed with SebType's own key, which never goes into the repo or a release.
`sebtype/build.sh` reads it from `~/.config/sebtype/` (or `SEBTYPE_KEY_DIR`): `sebtype-release.jks`
(alias `sebtype`) and its password in `keystore.password`. Keep an offline backup of that folder.
Android only accepts updates signed with the same key: losing it means uninstalling SebType and
reinstalling it, which wipes its learned words and settings.

## Publishing a release

From a clean checkout of `origin/main`:

```
sebtype/release.sh
```

It builds the signed arm64 release APK under the shared build lock
(`/tmp/agent-locks/sebtype/build.lock`) and runs `gh release create` with tag
`v<FUTO version>-sebtype.<n>`, where `<n>` is the number of commits on main (also the version code,
so every release from main upgrades the previous one). Needs JDK 21 in `~/.local/share/jdks/` (or
`JAVA_HOME_21`), the Android SDK with NDK 28.2 in `~/Android/Sdk` (or `ANDROID_HOME`)
and a logged-in `gh`.
