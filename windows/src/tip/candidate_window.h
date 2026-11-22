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

// sebtype.conf [Candidates] PinyinRow (#447): 中文's pinyin in the window's top row (the default, as Weasel
// drew it), else in the app's text as 日本語's kana are.
bool pinyinRowSetting();

class CandidateWindow {
 public:
  explicit CandidateWindow(TextService &service) : service_(service) {}
  ~CandidateWindow();

  // Shows the reply's page (and its pinyin row when preeditRow) below the caret, or hides when there is
  // nothing to show.
  void show(const Reply &reply, bool preeditRow, const RECT &caret);
  // The popup after a switch, for a moment; in Picnic, in the colour of the tray key pc/icons' icon (#476).
  void notice(const std::string &text, const std::string &icon, const RECT &caret);
  bool noticing() const { return noticing_; }
  void hide();

 private:
  // The style: Weasel's layout in Windows' own colours or SebType's Picnic, at the monitor's scale.
  struct Style {
    bool vertical = true, picnic = false;
    UINT dpi = 0;
    float scale = 1, fontPx = 0;
    Palette colors;
  };

  static LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
  bool create();
  void loadStyle(UINT dpi);
  void rescale(UINT dpi);
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
  RECT caret_{};  // where it was last shown
  // The word whose pages are shown: they keep its first page's width.
  std::wstring word_;
  int wheel_ = 0;  // the wheel's turn not yet a page
  bool noticing_ = false;  // a notice shows, until its timer
  uint32_t pillBorder_ = 0;  // the notice's border in Picnic, else 0: the style's
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
