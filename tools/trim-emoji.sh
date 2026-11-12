#!/usr/bin/env bash
# Regenerates sebtype/res-stable/raw/emoji_i18n.jsondlgz from FUTO's (#56): emoji names for search,
# only in SebType's languages. The keyboard loads the names of its own language ("en", "zh" or "ja",
# EmojiAction.loadTranslationsForLanguage), so FUTO's other ~150 languages (4.7 MB) are never read.
set -euo pipefail
cd "$(dirname "$0")/.."
# FUTO's emoji names, from its keyboard-large-resources repo at d87d9db
futo=$(mktemp); trap 'rm -f "$futo"' EXIT
curl -fsSL -o "$futo" https://gitlab.futo.org/keyboard/keyboard-large-resources/-/raw/d87d9dbdf3966bbe18413be375dab2f6c7bbdfdd/raw/emoji_i18n.jsondlgz
echo "53adbe577bbad4ad80d76bc8ac4cda094c98ecb46c14dc2f7fc9cfc7e80ddc9e  $futo" | sha256sum -c --status ||
  { echo "trim-emoji: FUTO's emoji file doesn't match its checksum" >&2; exit 1; }
zcat "$futo" |
  awk '/^#/ {keep = ($1 == "#en" || $1 == "#zh" || $1 == "#ja")} keep' |
  gzip -9n > sebtype/res-stable/raw/emoji_i18n.jsondlgz
