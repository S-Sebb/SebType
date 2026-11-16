// SebType on Windows: the candidate window, drawn in the app like Weasel's: the pinyin row (Chinese), the
// candidates across or down, in Windows' colours (#279) or SebType's Picnic with the pig (#162). Also the short
// popup after 中文's Shift switch. Page arrows, a click or the mouse wheel page (#276). MIT, SebType.
#pragma once

#include "candidate_layout.h"
#include "tip.h"

#include <d2d1.h>
#include <dwrite.h>

#include <string>
#include <vector>

namespace sebtype::win {

class CandidateWindow {
 public:
  explicit CandidateWindow(TextService &service) : service_(service) {}
  ~CandidateWindow();

  // Shows the reply's page (and its pinyin row when preeditRow) below the caret, or hides when there is
  // nothing to show.
  void show(const Reply &reply, bool preeditRow, const RECT &caret);
  // The popup after a switch, for a moment.
  void notice(const std::string &text, const RECT &caret);
  void hide();

 private:
  // The style: Weasel's layout in Windows' own colours or SebType's Picnic, at the monitor's scale.
  struct Style {
    bool vertical = true, picnic = false;
    float scale = 1, fontPx = 0;
    Palette colors;
  };

  static LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
  bool create();
  void loadStyle(const RECT &caret);
  void layout(const RECT &caret);
  void draw();
  void place(const RECT &caret);
  void page(bool next);
  IDWriteTextLayout *textLayout(const std::wstring &text);
  Box measure(const std::wstring &text, float x, float y);
  ID2D1Bitmap *pig();

  TextService &service_;
  HWND hwnd_ = nullptr;
  Style style_;
  bool styleLoaded_ = false;
  // What is shown and where.
  CandidateLayout layout_;
  int preeditHighlight_ = -1;
  int cursor_ = -1;
  // The word whose pages are shown: they keep its first page's width.
  std::wstring word_;
  int wheel_ = 0;  // the wheel's turn not yet a page
  // Direct2D and DirectWrite, made once per window.
  ID2D1Factory *d2d_ = nullptr;
  IDWriteFactory *dwrite_ = nullptr;
  IDWriteTextFormat *format_ = nullptr;
  ID2D1DCRenderTarget *target_ = nullptr;
  ID2D1StrokeStyle *round_ = nullptr;  // the arrows' round ends
  ID2D1Bitmap *pig_ = nullptr;
  float formatPx_ = 0;
};

}  // namespace sebtype::win
