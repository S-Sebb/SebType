// The candidate window's layout (windows/src/tip/candidate_layout.h) with made-up text sizes: page arrows,
// a word's width kept over its pages, wrapping, and what a click hits (#276); and its colours, which follow
// Windows or are Picnic's, readable in each (#279). Builds anywhere:
//   c++ -std=c++20 -I windows/src/tip windows/test/candidate_layout_test.cpp windows/src/tip/candidate_layout.cpp
// MIT, SebType.
#include "candidate_layout.h"

#include <cstdio>
#include <string>

using sebtype::win::Box;
using sebtype::win::CandidateLayout;

namespace {

int failures = 0;
#define CHECK(cond)                                                \
  do {                                                             \
    if (!(cond)) {                                                 \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                  \
    }                                                              \
  } while (0)

// Every character 10 px wide and 20 px tall.
Box measure(const std::wstring &text, float x, float y) { return {x, y, x + 10.0f * text.size(), y + 20}; }

CandidateLayout page(bool vertical, std::initializer_list<const wchar_t *> words, float keepWidth = 0) {
  CandidateLayout l;
  l.vertical = vertical;
  l.preedit = {L"ni hao"};
  int n = 0;
  for (const wchar_t *w : words) l.cells.push_back({std::to_wstring(++n) + L".", w, L""});
  l.hasPrev = keepWidth > 0, l.hasNext = true;
  l.keepWidth = keepWidth;
  l.maxWidth = 1000;
  l.run(measure);
  return l;
}

bool sameRow(const CandidateLayout &l, size_t a, size_t b) { return l.cells[a].all.t == l.cells[b].all.t; }

}  // namespace

int main() {
  // Across: the first page on one row, the arrows at the top right, in the pinyin row.
  const auto first = page(false, {L"你好", L"拟好", L"你", L"尼", L"泥", L"逆"});
  CHECK(sameRow(first, 0, 5));
  CHECK(first.nextBox.r == first.width - 12);
  CHECK(first.nextBox.t == first.preeditBoxes[0].t && first.nextBox.b == first.preeditBoxes[0].b);
  CHECK(first.prevBox.r < first.nextBox.l);
  CHECK(first.preeditBoxes[0].r < first.prevBox.l);
  CHECK(first.cells.back().all.r <= first.width - 12);

  // A later page with long candidates keeps the width and wraps: taller, not wider, the arrows in place.
  const auto later = page(false, {L"中华人民共和国国务院", L"中华人民共和国", L"中华人民", L"中华", L"中"}, first.width);
  CHECK(later.width == first.width);
  CHECK(later.height > first.height);
  CHECK(!sameRow(later, 0, 4));
  CHECK(later.nextBox.l == first.nextBox.l && later.nextBox.t == first.nextBox.t);
  for (const auto &c : later.cells) CHECK(c.all.r <= later.width - 12);
  // A short later page keeps the width too.
  CHECK(page(false, {L"你"}, first.width).width == first.width);
  // One candidate wider than the kept width widens the box for it.
  const auto wide = page(false, {L"一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十一二三四五六七八九十"}, first.width);
  CHECK(wide.width > first.width);

  // The monitor's width: the first page wraps within it.
  {
    CandidateLayout l;
    l.vertical = false;
    for (int i = 0; i < 9; ++i) l.cells.push_back({L"1.", L"中华人民共和国", L""});
    l.maxWidth = 400;
    l.run(measure);
    CHECK(l.width <= 400);
    CHECK(!sameRow(l, 0, 8));
  }

  // Down: arrows in the same spot; the first page's width kept, widened only for a longer candidate.
  const auto down = page(true, {L"你好", L"拟好", L"你"});
  CHECK(down.nextBox.r == down.width - 12 && down.nextBox.t == down.preeditBoxes[0].t);
  CHECK(page(true, {L"你"}, down.width).width == down.width);
  CHECK(page(true, {L"中华人民共和国国务院中华人民共和国"}, down.width).width > down.width);

  // The pig (Picnic) sits left; the arrows stay at the right edge.
  {
    CandidateLayout l;
    l.vertical = false, l.picnic = true;
    l.preedit = {L"ni hao"};
    l.cells = {{L"1.", L"你好", L""}, {L"2.", L"你", L""}};
    l.hasNext = true;
    l.run(measure);
    CHECK(!l.pigBox.empty() && l.pigBox.r < l.cells[0].all.l && l.pigBox.r < l.preeditBoxes[0].l);
    CHECK(l.nextBox.r == l.width - 12);
  }

  // Clicks: a candidate, an arrow, and the faint arrow of a page that doesn't exist.
  CHECK(first.hit(first.cells[2].all.l + 1, first.cells[2].all.t + 1) == 2);
  CHECK(first.hit(first.nextBox.l + 1, first.nextBox.t + 1) == CandidateLayout::kNext);
  CHECK(first.hit(first.prevBox.l + 1, first.prevBox.t + 1) == CandidateLayout::kNone);
  CHECK(later.hit(later.prevBox.l + 1, later.prevBox.t + 1) == CandidateLayout::kPrev);
  CHECK(later.hit(later.cells[4].all.l + 1, later.cells[4].all.b - 1) == 4);
  CHECK(first.hit(1, 1) == CandidateLayout::kNone);

  // No other page: no arrows.
  {
    CandidateLayout l;
    l.preedit = {L"a"};
    l.cells = {{L"1.", L"啊", L""}};
    l.run(measure);
    CHECK(l.prevBox.empty() && l.nextBox.empty());
  }

  // The window reuses one layout: a popup after a Picnic page with arrows has neither arrows nor pig (#348).
  {
    CandidateLayout l;
    l.vertical = false, l.picnic = true;
    l.preedit = {L"ni"};
    l.cells = {{L"1.", L"你", L""}};
    l.hasNext = true;
    l.maxWidth = 1000;
    l.run(measure);
    CHECK(!l.nextBox.empty() && !l.pigBox.empty());
    l.preedit = {L"日本語暂不可用"};
    l.cells.clear();
    l.hasPrev = l.hasNext = false;
    l.run(measure);
    CHECK(l.prevBox.empty() && l.nextBox.empty() && l.pigBox.empty());
  }

  // A word's pages: Rime's pinyin row moves its spaces and highlight; Mozc's converted segment changes.
  using sebtype::win::pageWord;
  CHECK(pageWord({L"ni hao"}, 0, true) == pageWord({L"ni", L"hao"}, 0, true));
  CHECK(pageWord({L"ni hao"}, 0, true) != pageWord({L"ni hao", L"m"}, 0, true));
  CHECK(pageWord({L"今日", L"は"}, 0, false) == pageWord({L"京", L"は"}, 0, false));
  CHECK(pageWord({L"今日", L"は"}, 0, false) != pageWord({L"今日", L"は"}, 1, false));
  CHECK(pageWord({L"きょう"}, -1, false) != pageWord({L"きょうは"}, -1, false));

  // Colours. Every text, the comments and the faint arrow readable on what they sit on, in light and dark
  // mode with a pale and a deep accent, and in Windows' high-contrast themes.
  using sebtype::win::contrast;
  using sebtype::win::Palette;
  using sebtype::win::SystemColors;
  auto readable = [](const Palette &p) {
    CHECK(contrast(p.text, p.back) >= 4.5);
    CHECK(contrast(p.candText, p.back) >= 4.5);
    CHECK(contrast(p.comment, p.back) >= 4.5);
    CHECK(contrast(p.hiliteText, p.hiliteBack) >= 4.5);
    CHECK(contrast(p.candHiliteText, p.candHiliteBack) >= 4.5);
    CHECK(contrast(p.faint, p.back) >= 3);
    CHECK(contrast(p.faint, p.back) < contrast(p.text, p.back));  // still fainter than a page that exists
  };
  // Accent shades as Windows 11 makes them: its default blue, and yellow (a pale accent).
  const SystemColors blue{false, false, 0x4cc2ff, 0x0067c0}, yellow{false, false, 0xffe980, 0xc29b00};
  for (SystemColors c : {blue, yellow}) {
    for (bool dark : {false, true}) {
      c.dark = dark;
      const Palette p = sebtype::win::systemPalette(c);
      readable(p);
      CHECK(p.candHiliteBack == (dark ? c.accentLight2 : c.accentDark1));
      CHECK(dark == (p.back < 0x808080));
    }
  }
  // High contrast: the theme's own colours (Night sky's and Desert's).
  const SystemColors night{true, false, 0, 0, 0x000000, 0xffffff, 0x8ee3f0, 0x263b50, 0xa6a6a6},
      desert{true, false, 0, 0, 0xfffaef, 0x3d3d3d, 0x903909, 0xfff5e3, 0x676767};
  for (const SystemColors &c : {night, desert}) {
    const Palette p = sebtype::win::systemPalette(c);
    readable(p);
    CHECK(p.back == c.window && p.candHiliteBack == c.highlight && p.faint == c.grayText);
    // A high-contrast theme wins over the light or dark mode.
    SystemColors darkToo = c;
    darkToo.dark = true;
    CHECK(sebtype::win::systemPalette(darkToo).back == c.window);
  }
  // Picnic stays as it was.
  const Palette picnic = sebtype::win::picnicPalette();
  CHECK(picnic.back == 0xfff7e8 && picnic.candHiliteBack == 0xc2506a && picnic.comment == 0x73533f);

  std::printf("%s candidate layout\n", failures ? "FAIL" : "PASS");
  return failures ? 1 : 0;
}
