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
  // Where a touch keyboard's key was tapped, in the pixels of the Layout it gave the engine; -1: not known
  // (the key's centre is taken).
  int x = -1, y = -1;
};
// A touch keyboard sends characters: a tap of "a" is keysym a. Latin-1 keysyms are their code points, any
// other character is X11's Unicode keysym.
constexpr uint32_t charSym(char32_t c) { return c < 0x100 ? c : 0x1000000 + c; }

enum class Lang { English, Chinese, Japanese };

// A touch keyboard's keys, for engines that correct taps near another key (English): each character key's
// rectangle in the keyboard's pixels.
struct KeyRect {
  char32_t code = 0;
  int x = 0, y = 0, width = 0, height = 0;
};
struct Layout {
  int width = 0, height = 0;
  std::vector<KeyRect> keys;
};

// What the text field takes, as a touch keyboard learns it from the field (the PCs type in Text).
// Plain: a field that wants no suggestions (URLs, e-mail addresses), where 中文 types letters.
enum class Field { Text, Plain, Number, Phone, Password };
// Mozc's request for the keys on screen: kana (romaji), letters or symbols.
enum class Keys { Kana, Letters, Symbols };
// What a touch keyboard does to the field's text around a commit, in characters: the text to delete
// around the cursor first (Mozc's deletion range), and where the cursor goes after it (0: after the
// commit; -n: n characters back, as Mozc puts it inside a pair of brackets; +n: n on, over a space already there).
// recompose: the composing text becomes the field's text from composeBefore characters before the cursor
// to composeAfter after it, first, as it is (English reopening a word, #280); with neither, the composing
// text ends where it is.
struct Edit {
  int deleteBefore = 0, deleteAfter = 0;
  int cursor = 0;
  bool recompose = false;
  int composeBefore = 0, composeAfter = 0;
};

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
