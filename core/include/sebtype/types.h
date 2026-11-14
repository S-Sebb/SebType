// SebType core: the types the core and its frontends share. MIT, SebType.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace sebtype {

// Keys use X11 keysyms and modifier bits on every platform: librime takes them as they are, and Mozc's
// key translation was written for them. A frontend converts its platform's keys once.
namespace mod {
constexpr uint32_t Shift = 1 << 0, Lock = 1 << 1, Ctrl = 1 << 2, Alt = 1 << 3, Super = 1 << 6;
}
struct Key {
  uint32_t sym = 0;
  uint32_t mods = 0;
  bool release = false;
};

enum class Lang { English, Chinese, Japanese };

struct Segment {
  std::string text;
  bool underline = false, highlight = false;
};
// What is being typed. cursor is in bytes, -1 for none.
struct Preedit {
  std::vector<Segment> segments;
  int cursor = -1;
  bool empty() const { return segments.empty(); }
  std::string text() const;
};

struct Candidate {
  std::string text, comment;
};
// One page of candidates as the window shows it. labels is empty when keys don't pick them.
struct Page {
  std::vector<Candidate> items;
  std::vector<std::string> labels;
  int cursor = -1;
  bool hasPrev = false, hasNext = false;
  bool empty() const { return items.empty(); }
};

// The tray menu. Frontends add their platform's own items (Linux: Restart, Exit) after it.
struct MenuItem {
  enum Kind { Language, Switch, Separator };
  Kind kind = Separator;
  std::string label;
  std::string icon;  // Language items: the language's icon id
  bool checked = false;
  Lang lang = Lang::English;  // Language items
};

}  // namespace sebtype
