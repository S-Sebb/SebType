#!/usr/bin/env bash
# Regenerates sebtype/res-stable/raw/emoji_i18n.jsondlgz from FUTO's (#56): emoji names for search,
# only in SebType's languages. The keyboard loads the names of its own language ("en", "zh" or "ja",
# EmojiAction.loadTranslationsForLanguage), so FUTO's other ~150 languages (4.7 MB) are never read.
set -euo pipefail
cd "$(dirname "$0")/.."
zcat java/res-large/raw/emoji_i18n.jsondlgz |
  awk '/^#/ {keep = ($1 == "#en" || $1 == "#zh" || $1 == "#ja")} keep' |
  gzip -9n > sebtype/res-stable/raw/emoji_i18n.jsondlgz
