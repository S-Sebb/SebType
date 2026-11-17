// SebType core: the settings every platform shares, in sebtype.conf. MIT, SebType.
#pragma once

#include <sebtype/types.h>

#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace sebtype {

struct Settings {
  // Languages that are on, in order. The first is Win+Space's home language on the PCs (#93); the phone's
  // 🌐 goes through them in this order.
  std::vector<Lang> languages{Lang::English, Lang::Chinese, Lang::Japanese};
  // 中文's options. Unset leaves the engine's own (the PCs still keep them in Rime's files).
  std::optional<bool> traditional, fullWidthPunctuation, emoji;
  // 日本語's: a space is always half-width (unset: Mozc's, full-width in kana).
  std::optional<bool> halfWidthSpace;
  // Learning from what is typed, in every language.
  bool learning = true;
  // Leaving a language types in what is typed, as focus moving away does (the PCs' Win+Space, #301), or
  // drops it (the phone's 🌐, the user's choice of 2026-11-15). A platform's, so not in the file.
  bool commitOnSwitch = true;

  static Settings parse(std::string_view ini);
  std::string serialize() const;
};

}  // namespace sebtype
