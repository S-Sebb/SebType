// SebType core: a language that isn't ready to take keys (#275), as the tray and the popup by the caret say
// it. The core says it for its engines; Windows' text service also for a server that doesn't answer. MIT,
// SebType.
#pragma once

#include <sebtype/types.h>

#include <string>

namespace sebtype {

enum class Readiness {
  Ready,
  Preparing,    // Rime deploying or saving, Mozc loading
  Unavailable,  // the engine didn't load, or the server doesn't answer
};

// The tray icon: the language's key in grey, with "…" (wait) or "!" (off).
inline std::string notReadyIcon(Lang lang, Readiness r) {
  return std::string(lang == Lang::Japanese ? "hira" : "zh") + (r == Readiness::Preparing ? "-wait" : "-off");
}

// The popup at the first key typed meanwhile, in the system's language: the key goes in as typed.
inline std::string notReadyNotice(Lang lang, Readiness r, Lang ui) {
  const std::string name = lang == Lang::Japanese ? "日本語" : "中文";
  const bool preparing = r == Readiness::Preparing;
  if (ui == Lang::Chinese) return name + (preparing ? "准备中…先按英文字母输入" : "暂不可用 · 按英文字母输入");
  if (ui == Lang::Japanese) return name + (preparing ? "を準備中…英字のまま入力します" : "は使えません・英字のまま入力します");
  return name + (preparing ? " is getting ready: letters go in as typed" : " isn't available: letters go in as typed");
}

}  // namespace sebtype
