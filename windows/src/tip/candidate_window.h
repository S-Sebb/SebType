// SebType on Windows: the candidate window, drawn in the app like Weasel's: the pinyin row (Chinese), the
// candidates across or down, in Weasel's default look or SebType's Picnic with the pig (#162). Also the short
// popup after 中文's Shift switch. MIT, SebType.
#pragma once

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
  // A rectangle in pixels.
  struct Box {
    float l = 0, t = 0, r = 0, b = 0;
    bool empty() const { return r <= l; }
    void move(float x, float y) { l += x, r += x, t += y, b += y; }
  };
  struct Cell {
    std::wstring label, text, comment;
    Box all, labelBox, textBox, commentBox;
  };
  // The style: Weasel's layout and its aqua or SebType's Picnic colours, at the monitor's scale.
  struct Style {
    bool vertical = true, picnic = false;
    float scale = 1, fontPx = 0;
    UINT32 text, back, border, hiliteText, hiliteBack, candText, comment, candHiliteText, candHiliteBack;
  };

  static LRESULT CALLBACK proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam);
  bool create();
  void loadStyle(const RECT &caret);
  void layout();
  void draw();
  void place(const RECT &caret);
  IDWriteTextLayout *textLayout(const std::wstring &text);
  Box measure(const std::wstring &text, float x, float y);
  ID2D1Bitmap *pig();

  TextService &service_;
  HWND hwnd_ = nullptr;
  Style style_;
  bool styleLoaded_ = false;
  // What is shown.
  std::vector<std::wstring> preedit_;  // segments
  int preeditHighlight_ = -1;
  std::wstring aux_;
  std::vector<Cell> cells_;
  int cursor_ = -1;
  // Its layout, in pixels.
  float width_ = 0, height_ = 0;
  std::vector<Box> preeditBoxes_;
  Box auxBox_, pigBox_;
  // Direct2D and DirectWrite, made once per window.
  ID2D1Factory *d2d_ = nullptr;
  IDWriteFactory *dwrite_ = nullptr;
  IDWriteTextFormat *format_ = nullptr;
  ID2D1DCRenderTarget *target_ = nullptr;
  ID2D1Bitmap *pig_ = nullptr;
  float formatPx_ = 0;
};

}  // namespace sebtype::win
