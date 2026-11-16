// SebType on Windows: the candidate window's layout. Its sizes are weasel.yaml's defaults, as SebType's Weasel
// drew them; the page arrows and the wrapping are SebType's (#276). MIT, SebType.
#include "candidate_layout.h"

#include <algorithm>
#include <cmath>

namespace sebtype::win {
namespace {

// weasel.yaml's layout, in pixels at 100 %.
constexpr float kMargin = 12, kSpacing = 10, kCandidateSpacing = 5, kHiliteSpacing = 4, kMinWidth = 160;
// The pig: its picture's size, and the gap between it and the candidates (as SebType's Weasel drew it, #162).
constexpr float kPigWidth = 158, kPigHeight = 160, kPigGap = 9;
// The page arrows: each as wide as this much of a text row, with this gap between them (#276).
constexpr float kArrowWidth = 0.8f, kArrowGap = 4;

}  // namespace

void CandidateLayout::run(const Measure &measure) {
  const float s = scale;
  const float margin = std::round(kMargin * s), spacing = std::round(kSpacing * s),
              candSpacing = std::round(kCandidateSpacing * s), space = std::round(kHiliteSpacing * s),
              minWidth = std::round(kMinWidth * s);
  const bool arrows = hasPrev || hasNext;
  const Box line = measure(L"‹›", 0, 0);
  const float lineH = line.b - line.t, arrowW = std::round(lineH * kArrowWidth),
              arrowsW = arrows ? 2 * arrowW + std::round(kArrowGap * s) : 0;

  // The pig's room at the left, from the first candidate row's height and the window's (which the wrapping
  // can change: a first pass finds the room, a second lays out beside it).
  float shift = 0, pigW = 0, pigH = 0;
  for (int pass = 0; pass < 2; ++pass) {
    // Each cell's parts side by side from 0, 0; the across layout moves them into place.
    for (Cell &c : cells) {
      float x = 0;
      c.labelBox = measure(c.label, x, 0);
      if (!c.label.empty() || !vertical) x = c.labelBox.r + space;
      c.textBox = measure(c.text, x, 0);
      c.commentBox = {};
      if (!c.comment.empty() && !vertical) c.commentBox = measure(c.comment, c.textBox.r + space, 0);
      c.all = {0, 0, c.commentBox.empty() ? c.textBox.r : c.commentBox.r,
               std::max({c.labelBox.b, c.textBox.b, c.commentBox.b})};
    }

    float y = margin, right = 0;  // right: the widest row's end, without the pig
    auto row = [&](float r) { right = std::max(right, r); };

    // The pinyin row (or else Rime's or Mozc's note) with the arrows at its right; a row of their own when
    // there is neither.
    preeditBoxes.clear();
    float topH = 0;
    if (!preedit.empty()) {
      float x = margin;
      for (const auto &seg : preedit) {
        const Box b = measure(seg, x, y);
        preeditBoxes.push_back(b);
        x = b.r, topH = std::max(topH, b.b - b.t);
      }
      row(x + (arrows ? spacing + arrowsW : 0));
    }
    auxBox = {};
    if (!aux.empty()) {
      const float auxY = preedit.empty() ? y : y + topH + spacing;
      auxBox = measure(aux, margin, auxY);
      if (preedit.empty()) topH = auxBox.b - auxBox.t;
      row(auxBox.r + (arrows && preedit.empty() ? spacing + arrowsW : 0));
    }
    const float arrowTop = y;
    if (!preedit.empty() || !aux.empty()) {
      y = (aux.empty() ? y + topH : auxBox.b) + spacing;
    } else if (arrows && !cells.empty()) {
      topH = lineH;
      row(margin + arrowsW);
      y += topH + spacing;
    }

    if (cells.empty()) {
      width = std::max(right + margin, keepWidth - shift);
      height = y - spacing + margin;
      break;
    }
    const float top = y;
    // The width this page needs on its own; across, a row that doesn't fit wraps, so it needs only its
    // widest candidate.
    float inner = 0, widest = 0;  // inner: all on one row across, or the widest row down
    for (size_t i = 0; i < cells.size(); ++i) {
      const float w = cells[i].all.r;
      widest = std::max(widest, w);
      inner = vertical ? 0 : inner + (i ? candSpacing : 0) + w;
    }
    float commentLeft = 0, commentRight = 0;
    if (vertical) {
      // Comments in a column of their own after the widest candidate.
      commentLeft = margin + widest + space;
      commentRight = margin + widest;
      for (Cell &c : cells)
        if (!c.comment.empty()) commentRight = std::max(commentRight, commentLeft + measure(c.comment, 0, 0).r);
      inner = commentRight - margin;
    }
    // Down, or a word's first page across: the width it needs, within the monitor. A later page keeps the first
    // one's and widens only for what can't fit in it: a candidate across, the column down.
    const float fit = margin + (vertical ? inner : widest) + margin;
    const float w = keepWidth > 0 ? std::max(keepWidth - shift, fit) : margin + inner + margin;
    width = std::max(std::min(std::max({w, right + margin, minWidth}), maxWidth - shift), fit);

    if (vertical) {
      for (size_t i = 0; i < cells.size(); ++i) {
        Cell &c = cells[i];
        if (i) y += candSpacing;
        for (Box *b : {&c.labelBox, &c.textBox}) b->move(margin, y);
        c.all = {margin, y, width - margin, y + c.all.b};
        if (!c.comment.empty()) c.commentBox = measure(c.comment, commentLeft, c.textBox.t);
        y = c.all.b;
      }
    } else {
      // Left to right, wrapping before a candidate that would end past the margin.
      float x = margin, h = 0;
      size_t rowStart = 0;
      auto endRow = [&](size_t end) {
        for (size_t j = rowStart; j < end; ++j) cells[j].all.b = cells[j].all.t + h;
        y += h;
      };
      for (size_t i = 0; i < cells.size(); ++i) {
        Cell &c = cells[i];
        const float cw = c.all.r, ch = c.all.b;
        if (i && x + candSpacing + cw > width - margin) {
          endRow(i);
          y += candSpacing, x = margin, h = 0, rowStart = i;
        } else if (i) {
          x += candSpacing;
        }
        for (Box *b : {&c.labelBox, &c.textBox, &c.commentBox}) b->move(x, y);
        c.all = {x, y, x + cw, y};
        x += cw, h = std::max(h, ch);
      }
      endRow(cells.size());
    }
    height = y + margin;

    // The arrows: right on the top row, as tall as a text row and centred on it.
    prevBox = nextBox = {};
    if (arrows) {
      const float t = arrowTop + std::round((topH - lineH) / 2);
      nextBox = {width - margin - arrowW, t, width - margin, t + lineH};
      prevBox = nextBox;
      prevBox.move(-(arrowsW - arrowW), 0);
    }

    pigBox = {};
    if (!picnic) break;
    // The pig, left of the rows from the first one down: its height is the first candidate row's and a margin,
    // by 10/7, within the window.
    if (pass == 0) {
      const float rowH = cells[0].all.b - cells[0].all.t;
      pigH = std::floor(std::min((rowH + margin) * 10 / 7, height));
      pigW = std::floor(pigH * kPigWidth / kPigHeight);
      shift = pigW + std::floor(margin / 2) + std::floor(kPigGap * s);
      continue;  // narrower rows wrap sooner, so the window only grows taller: the pig still fits
    }
    float pigTop = preedit.empty() && aux.empty() && !arrows ? top : margin;
    pigTop = std::min(pigTop, height - pigH);
    pigBox = {margin, pigTop, margin + pigW, pigTop + pigH};
    for (Box &b : preeditBoxes) b.move(shift, 0);
    auxBox.move(shift, 0);
    for (Cell &c : cells)
      for (Box *b : {&c.all, &c.labelBox, &c.textBox, &c.commentBox}) b->move(shift, 0);
    width += shift;
    // The arrows stay at the right edge.
    prevBox.move(shift, 0), nextBox.move(shift, 0);
    break;
  }
}

int CandidateLayout::hit(float x, float y) const {
  if (hasPrev && prevBox.contains(x, y)) return kPrev;
  if (hasNext && nextBox.contains(x, y)) return kNext;
  for (size_t i = 0; i < cells.size(); ++i)
    if (cells[i].all.contains(x, y)) return static_cast<int>(i);
  return kNone;
}

std::wstring pageWord(const std::vector<std::wstring> &segments, int highlight, bool pinyin) {
  std::wstring key;
  for (size_t i = 0; i < segments.size(); ++i) {
    if (pinyin) {
      for (wchar_t c : segments[i])
        if (c != L' ') key += c;
    } else {
      key += (static_cast<int>(i) == highlight ? L"\x1" : segments[i]) + L'\x2';
    }
  }
  return key;
}

}  // namespace sebtype::win
