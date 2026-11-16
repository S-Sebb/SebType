// SebType on Windows: where the candidate window puts things, apart from Windows so it can be tested
// (windows/test). The window measures text with DirectWrite and draws what this lays out. MIT, SebType.
#pragma once

#include <functional>
#include <limits>
#include <string>
#include <vector>

namespace sebtype::win {

// A rectangle in pixels.
struct Box {
  float l = 0, t = 0, r = 0, b = 0;
  bool empty() const { return r <= l; }
  bool contains(float x, float y) const { return x >= l && x < r && y >= t && y < b; }
  void move(float x, float y) { l += x, r += x, t += y, b += y; }
};

// A text's box with its top left at x, y.
using Measure = std::function<Box(const std::wstring &text, float x, float y)>;

struct CandidateLayout {
  struct Cell {
    std::wstring label, text, comment;
    Box all, labelBox, textBox, commentBox;
  };

  // What to lay out.
  bool vertical = true, picnic = false;
  float scale = 1;
  std::vector<std::wstring> preedit;  // the pinyin row's segments
  std::wstring aux;
  std::vector<Cell> cells;
  bool hasPrev = false, hasNext = false;  // the page arrows show when either is
  // The width this word's pages had so far: the box keeps it and only grows taller (0: the first page).
  float keepWidth = 0;
  // The monitor's: candidates across wrap to stay within it.
  float maxWidth = std::numeric_limits<float>::infinity();

  // Where it went.
  float width = 0, height = 0;
  std::vector<Box> preeditBoxes;
  Box auxBox, pigBox, prevBox, nextBox;  // the arrows are empty when hidden

  void run(const Measure &measure);

  // What a click at x, y hits: a candidate's index on the page, kPrev or kNext (only while that page
  // exists), or kNone.
  static constexpr int kNone = -1, kPrev = -2, kNext = -3;
  int hit(float x, float y) const;
};

}  // namespace sebtype::win
