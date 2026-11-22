// SebType's tray key (Set E, #63): its base's colours, for the switch popup's pill (#476). Written by
// pc/icons/build.py from its own: change them there.
#pragma once

#include <cstdint>
#include <string_view>

namespace sebtype::keycap {

// The base's top colour of the tray key pc/icons/<size>/<icon>.png: its language's, grey while not ready.
constexpr uint32_t base(std::string_view icon) {
  if (icon == "en") return 0xcdbbf0;
  if (icon == "zh") return 0xf6a9b9;
  if (icon == "zh-a") return 0xf6a9b9;
  if (icon == "zh-caps") return 0xf6a9b9;
  if (icon == "hira") return 0xf9c252;
  if (icon == "kata") return 0xf9c252;
  if (icon == "ja-a") return 0xf9c252;
  if (icon == "ja-caps") return 0xf9c252;
  if (icon == "zh-wait") return 0xd9d3ce;
  if (icon == "zh-off") return 0xd9d3ce;
  if (icon == "hira-wait") return 0xd9d3ce;
  if (icon == "hira-off") return 0xd9d3ce;
  return 0xfff8e8;
}

}  // namespace sebtype::keycap
