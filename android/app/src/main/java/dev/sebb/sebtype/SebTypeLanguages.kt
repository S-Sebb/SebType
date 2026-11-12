package dev.sebb.sebtype

// SebType: English, Chinese and Japanese share one QWERTY key grid (android/app/src/main/assets/layouts/SebType;
// English uses FUTO's own qwerty). A fresh install sets them up in this order, which is also the
// globe cycle order: EN → 中 → 日. Locales are mapping.yaml keys, as "Add language" uses.
val SebTypeLanguages = listOf(
    "en_US" to "qwerty",
    "zh" to "sebtype_zh",
    "ja" to "sebtype_ja",
)
