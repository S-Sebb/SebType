// SebType's tray key (Set E, #63): its base's colours, for the switch popup's pill's border (#476). Written by
// pc/icons/build.py from its own: change them there.
#pragma once

#include <cstdint>
#include <string_view>

namespace sebtype::keycap {

// The base's bottom colour of the tray key pc/icons/<size>/<icon>.png: its language's, grey while not ready;
// else the key's outline.
constexpr uint32_t base(std::string_view icon) {
  if (icon == "en") return 0x9d86d8;
  if (icon == "zh") return 0xe07a92;
  if (icon == "zh-a") return 0xe07a92;
  if (icon == "zh-caps") return 0xe07a92;
  if (icon == "hira") return 0xec962a;
  if (icon == "kata") return 0xec962a;
  if (icon == "ja-a") return 0xec962a;
  if (icon == "ja-caps") return 0xec962a;
  if (icon == "zh-wait") return 0xafa6a0;
  if (icon == "zh-off") return 0xafa6a0;
  if (icon == "hira-wait") return 0xafa6a0;
  if (icon == "hira-off") return 0xafa6a0;
  return 0x5b331c;
}

}  // namespace sebtype::keycap
