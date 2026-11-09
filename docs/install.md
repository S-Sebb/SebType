# Installing SebType

SebType is published as GitHub releases of the private repo `S-Sebb/sebtype`, one arm64-v8a APK per
release. Obtainium installs and updates it using a read-only GitHub token. SebType's application id
is `dev.sebb.sebtype`, so it installs next to stock FUTO Keyboard and Gboard.

## 1. Make a read-only GitHub token

On GitHub: Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate new token.

- Token name: `Obtainium SebType`
- Expiration: your choice (Obtainium stops seeing updates when it expires; make a new one then)
- Resource owner: `S-Sebb`
- Repository access: Only select repositories → `S-Sebb/sebtype`
- Permissions → Repository permissions → Contents: **Read-only** (Metadata: Read-only is added automatically)

Nothing else. Copy the token (`github_pat_…`).

## 2. Give it to Obtainium

Obtainium → Settings → scroll to the GitHub source settings → **GitHub Personal Access Token**: paste the token.

## 3. Add SebType

Obtainium → Add App:

- App source URL: `https://github.com/S-Sebb/sebtype`
- Leave the defaults (latest release, APK asset) and tap Add, then Install.

Obtainium checks for new releases like for any other app.

## 4. Turn it on

Open SebType from the launcher and follow its setup (enable the keyboard, then pick it). Switch
between SebType, FUTO and Gboard with the navigation-bar keyboard icon.

## Signing key

Releases are signed with SebType's own key, kept on nobara-pc in `~/.config/sebtype/`
(`sebtype-release.jks`, password in `keystore.password`, alias `sebtype`); never in the repo.
Back that folder up offline. Android only accepts updates signed with the same key: losing it
means uninstalling SebType and reinstalling it, which wipes its learned words and settings.

## Publishing a release (nobara-pc)

From a clean checkout of `origin/main`:

```
sebtype/release.sh
```

It builds the signed arm64 release APK under the shared build lock and runs `gh release create`
with tag `v<FUTO version>-sebtype.<n>`, where `<n>` is the number of commits on main (also the
version code, so every release from main upgrades the previous one). Needs JDK 21 in
`~/.local/share/jdks/` (or `JAVA_HOME_21`), the Android SDK with NDK 28.2 in `~/Android/Sdk`,
`git-lfs` and a logged-in `gh`.
