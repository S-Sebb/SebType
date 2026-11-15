// SebType on Windows: the candidate window. Its sizes and colours are Weasel's defaults (weasel.yaml's style
// and its aqua scheme) and SebType's Picnic scheme with the pig, as the Configurator set them for Weasel, so
// the window looks as it did; the code is SebType's own. MIT, SebType.
#include "candidate_window.h"

#include "resource.h"

#include <shellscalingapi.h>
#include <shlwapi.h>
#include <wincodec.h>

#include <algorithm>
#include <cmath>
#include <filesystem>

namespace sebtype::win {
namespace {

const wchar_t kFont[] = L"Microsoft YaHei";
constexpr UINT_PTR kNoticeTimer = 1;
constexpr UINT kNoticeMs = 1200;  // Weasel's show_notifications_time

// weasel.yaml's layout, in pixels at 100 %.
constexpr float kMargin = 12, kSpacing = 10, kCandidateSpacing = 5, kHiliteSpacing = 4, kHilitePadding = 2,
                kRoundCorner = 4, kCornerRadius = 4, kBorder = 3, kMinWidth = 160;
// The pig: its picture's size, and the gap between it and the candidates (as SebType's Weasel drew it, #162).
constexpr float kPigWidth = 158, kPigHeight = 160, kPigGap = 9;

template <class T>
void release(T *&p) {
  if (p) p->Release();
  p = nullptr;
}

// Weasel's colours are 0xBBGGRR; Direct2D's ColorF takes 0xRRGGBB.
constexpr UINT32 rgb(UINT32 bgr) { return ((bgr & 0xff) << 16) | (bgr & 0xff00) | ((bgr >> 16) & 0xff); }

// sebtype.conf [Candidates], which the Configurator writes; Weasel's defaults otherwise: down, 14 pt, aqua.
struct Settings {
  bool vertical = true, picnic = false;
  int fontSize = 14;
};
Settings readSettings() {
  wchar_t appData[MAX_PATH] = L"";
  GetEnvironmentVariableW(L"APPDATA", appData, MAX_PATH);
  const std::wstring file = std::wstring(appData) + L"\\SebType\\sebtype.conf";
  Settings s;
  s.vertical = GetPrivateProfileIntW(L"Candidates", L"Vertical", 1, file.c_str()) != 0;
  s.picnic = GetPrivateProfileIntW(L"Candidates", L"Picnic", 0, file.c_str()) != 0;
  s.fontSize = std::clamp<int>(GetPrivateProfileIntW(L"Candidates", L"FontSize", 14, file.c_str()), 8, 72);
  return s;
}

}  // namespace

CandidateWindow::~CandidateWindow() {
  if (hwnd_) DestroyWindow(hwnd_);
  release(pig_);
  release(target_);
  release(format_);
  release(dwrite_);
  release(d2d_);
}

bool CandidateWindow::create() {
  if (hwnd_) return true;
  WNDCLASSEXW wc{sizeof(wc)};
  wc.lpfnWndProc = proc;
  wc.hInstance = dllInstance;
  wc.hCursor = LoadCursorW(nullptr, IDC_ARROW);
  wc.lpszClassName = kWindowClass;
  RegisterClassExW(&wc);  // fails harmlessly when this DLL registered it already
  hwnd_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE, kWindowClass, L"",
                          WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, dllInstance, nullptr);
  if (!hwnd_) return false;
  SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED, &d2d_)) ||
      FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                                 reinterpret_cast<IUnknown **>(&dwrite_))))
    return false;
  const auto props = D2D1::RenderTargetProperties(
      D2D1_RENDER_TARGET_TYPE_DEFAULT, D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM, D2D1_ALPHA_MODE_PREMULTIPLIED),
      96, 96);  // so a unit is a pixel
  return SUCCEEDED(d2d_->CreateDCRenderTarget(&props, &target_));
}

void CandidateWindow::loadStyle(const RECT &caret) {
  const Settings s = readSettings();
  UINT dpiX = 96, dpiY = 96;
  GetDpiForMonitor(MonitorFromRect(&caret, MONITOR_DEFAULTTONEAREST), MDT_EFFECTIVE_DPI, &dpiX, &dpiY);
  Style &st = style_;
  st.vertical = s.vertical;
  st.picnic = s.picnic;
  st.scale = dpiX / 96.0f;
  st.fontPx = s.fontSize * 96.0f / 72.0f * st.scale;
  if (s.picnic) {  // the Configurator's sebtype_picnic scheme (windows.rs)
    st.text = rgb(0x222f4a), st.back = rgb(0xe8f7ff), st.border = rgb(0x1c335b);
    st.hiliteText = rgb(0x222f4a), st.hiliteBack = rgb(0xe6e0fd);
    st.candText = rgb(0x222f4a), st.comment = rgb(0x3f5373);
    st.candHiliteText = rgb(0xffffff), st.candHiliteBack = rgb(0x6a50c2);
  } else {  // Weasel's aqua
    st.text = rgb(0x000000), st.back = rgb(0xeceeee), st.border = rgb(0xe0e0e0);
    st.hiliteText = rgb(0x000000), st.hiliteBack = rgb(0xd4d4d4);
    st.candText = rgb(0x000000), st.comment = st.candText;
    st.candHiliteText = rgb(0xffffff), st.candHiliteBack = rgb(0xfa3a0a);
  }
  if (format_ && formatPx_ != st.fontPx) release(format_);
  if (!format_ && SUCCEEDED(dwrite_->CreateTextFormat(kFont, nullptr, DWRITE_FONT_WEIGHT_NORMAL,
                                                      DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
                                                      st.fontPx, L"", &format_))) {
    format_->SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP);
    formatPx_ = st.fontPx;
  }
  styleLoaded_ = true;
}

IDWriteTextLayout *CandidateWindow::textLayout(const std::wstring &text) {
  IDWriteTextLayout *layout = nullptr;
  if (format_)
    dwrite_->CreateTextLayout(text.c_str(), static_cast<UINT32>(text.size()), format_, 1e5f, 1e5f, &layout);
  return layout;
}

CandidateWindow::Box CandidateWindow::measure(const std::wstring &text, float x, float y) {
  DWRITE_TEXT_METRICS m{};
  if (IDWriteTextLayout *layout = textLayout(text)) {
    layout->GetMetrics(&m);
    layout->Release();
  }
  return {x, y, x + std::ceil(m.widthIncludingTrailingWhitespace), y + std::ceil(m.height)};
}

void CandidateWindow::layout() {
  const float s = style_.scale;
  const float margin = std::round(kMargin * s), spacing = std::round(kSpacing * s),
              candSpacing = std::round(kCandidateSpacing * s), space = std::round(kHiliteSpacing * s);
  float width = 0, y = margin;
  auto row = [&](float right) { width = std::max(width, right + margin); };

  // The pinyin row, then Rime's or Mozc's note.
  preeditBoxes_.clear();
  if (!preedit_.empty()) {
    float x = margin, h = 0;
    for (const auto &seg : preedit_) {
      const Box b = measure(seg, x, y);
      preeditBoxes_.push_back(b);
      x = b.r, h = std::max(h, b.b - b.t);
    }
    row(x);
    y += h + spacing;
  }
  auxBox_ = {};
  if (!aux_.empty()) {
    auxBox_ = measure(aux_, margin, y);
    row(auxBox_.r);
    y += auxBox_.b - auxBox_.t + spacing;
  }

  if (cells_.empty()) {
    width_ = width, height_ = y - spacing + margin;
    pigBox_ = {};
    return;
  }
  const float top = y;
  if (style_.vertical) {
    // One candidate a row: label, text, and the comments in a column of their own.
    float textRight = 0;
    for (size_t i = 0; i < cells_.size(); ++i) {
      Cell &c = cells_[i];
      if (i) y += candSpacing;
      float x = margin;
      c.labelBox = measure(c.label, x, y);
      if (!c.label.empty()) x = c.labelBox.r + space;
      c.textBox = measure(c.text, x, y);
      textRight = std::max(textRight, c.textBox.r);
      y = std::max({c.labelBox.b, c.textBox.b});
    }
    float commentRight = textRight;
    for (Cell &c : cells_) {
      c.commentBox = {};
      if (c.comment.empty()) continue;
      c.commentBox = measure(c.comment, textRight + space, c.textBox.t);
      commentRight = std::max(commentRight, c.commentBox.r);
    }
    row(commentRight);
    width = std::max(width, std::round(kMinWidth * s));
    for (Cell &c : cells_) c.all = {margin, c.textBox.t, width - margin, std::max(c.textBox.b, c.labelBox.b)};
  } else {
    // All candidates in one row: label, text and comment, then the next.
    float x = margin, h = 0;
    for (size_t i = 0; i < cells_.size(); ++i) {
      Cell &c = cells_[i];
      if (i) x += candSpacing;
      const float left = x;
      c.labelBox = measure(c.label, x, y);
      x = c.labelBox.r + space;
      c.textBox = measure(c.text, x, y);
      x = c.textBox.r;
      c.commentBox = {};
      if (!c.comment.empty()) {
        c.commentBox = measure(c.comment, x + space, y);
        x = c.commentBox.r;
      }
      c.all = {left, y, x, 0};
      h = std::max({h, c.labelBox.b - y, c.textBox.b - y, c.commentBox.empty() ? 0 : c.commentBox.b - y});
    }
    for (Cell &c : cells_) c.all.b = y + h;
    y += h;
    row(x);
    width = std::max(width, std::round(kMinWidth * s));
    cells_.back().all.r = width - margin;
  }
  const float height = y + margin;

  // The pig, left of the rows from the first one down: its height is the first candidate row's and a margin,
  // by 10/7, within the window.
  pigBox_ = {};
  if (style_.picnic) {
    const float rowH = cells_[0].all.b - cells_[0].all.t;
    const float h = std::floor(std::min((rowH + margin) * 10 / 7, height));
    const float w = std::floor(h * kPigWidth / kPigHeight);
    float pigTop = preedit_.empty() && aux_.empty() ? top : margin;
    pigTop = std::min(pigTop, height - h);
    pigBox_ = {margin, pigTop, margin + w, pigTop + h};
    const float shift = w + std::floor(margin / 2) + std::floor(kPigGap * s);
    for (Box &b : preeditBoxes_) b.move(shift, 0);
    auxBox_.move(shift, 0);
    for (Cell &c : cells_)
      for (Box *b : {&c.all, &c.labelBox, &c.textBox, &c.commentBox}) b->move(shift, 0);
    width += shift;
  }
  width_ = width, height_ = height;
}

ID2D1Bitmap *CandidateWindow::pig() {
  if (pig_) return pig_;
  HRSRC res = FindResourceW(dllInstance, MAKEINTRESOURCEW(IDR_PIG), RT_RCDATA);
  HGLOBAL data = res ? LoadResource(dllInstance, res) : nullptr;
  if (!data) return nullptr;
  IStream *stream = SHCreateMemStream(static_cast<const BYTE *>(LockResource(data)), SizeofResource(dllInstance, res));
  IWICImagingFactory *wic = nullptr;
  IWICBitmapDecoder *decoder = nullptr;
  IWICBitmapFrameDecode *frame = nullptr;
  IWICFormatConverter *converter = nullptr;
  if (stream &&
      SUCCEEDED(CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&wic))) &&
      SUCCEEDED(wic->CreateDecoderFromStream(stream, nullptr, WICDecodeMetadataCacheOnLoad, &decoder)) &&
      SUCCEEDED(decoder->GetFrame(0, &frame)) && SUCCEEDED(wic->CreateFormatConverter(&converter)) &&
      SUCCEEDED(converter->Initialize(frame, GUID_WICPixelFormat32bppPBGRA, WICBitmapDitherTypeNone, nullptr, 0,
                                      WICBitmapPaletteTypeCustom)))
    target_->CreateBitmapFromWicBitmap(converter, &pig_);
  release(converter);
  release(frame);
  release(decoder);
  release(wic);
  release(stream);
  return pig_;
}

void CandidateWindow::draw() {
  const int w = static_cast<int>(std::ceil(width_)), h = static_cast<int>(std::ceil(height_));
  BITMAPINFO bi{};
  bi.bmiHeader = {sizeof(BITMAPINFOHEADER), w, -h, 1, 32, BI_RGB};
  void *bits = nullptr;
  HDC screen = GetDC(nullptr);
  HDC dc = CreateCompatibleDC(screen);
  HBITMAP bitmap = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HGDIOBJ old = SelectObject(dc, bitmap);
  const RECT all{0, 0, w, h};
  if (bitmap && SUCCEEDED(target_->BindDC(dc, &all))) {
    const float s = style_.scale, border = std::round(kBorder * s), pad = std::round(kHilitePadding * s);
    ID2D1SolidColorBrush *brush = nullptr;
    target_->BeginDraw();
    target_->Clear(D2D1::ColorF(0, 0));
    target_->CreateSolidColorBrush(D2D1::ColorF(style_.back), &brush);
    auto color = [&](UINT32 c) { brush->SetColor(D2D1::ColorF(c)); };
    auto fill = [&](const Box &b, float inflate, float radius, UINT32 c) {
      color(c);
      target_->FillRoundedRectangle(
          D2D1::RoundedRect(D2D1::RectF(b.l - inflate, b.t - inflate, b.r + inflate, b.b + inflate), radius, radius),
          brush);
    };
    auto text = [&](const std::wstring &t, const Box &b, UINT32 c) {
      IDWriteTextLayout *layout = textLayout(t);
      if (!layout) return;
      color(c);
      target_->DrawTextLayout(D2D1::Point2F(b.l, b.t), layout, brush);
      layout->Release();
    };

    // The card and its border.
    const auto card = D2D1::RoundedRect(
        D2D1::RectF(border / 2, border / 2, width_ - border / 2, height_ - border / 2), kCornerRadius * s,
        kCornerRadius * s);
    color(style_.back);
    target_->FillRoundedRectangle(card, brush);
    color(style_.border);
    target_->DrawRoundedRectangle(card, brush, border);

    for (size_t i = 0; i < preedit_.size(); ++i) {
      const bool hi = static_cast<int>(i) == preeditHighlight_;
      if (hi) fill(preeditBoxes_[i], pad, kRoundCorner * s, style_.hiliteBack);
      text(preedit_[i], preeditBoxes_[i], hi ? style_.hiliteText : style_.text);
    }
    if (!aux_.empty()) text(aux_, auxBox_, style_.text);
    for (size_t i = 0; i < cells_.size(); ++i) {
      const Cell &c = cells_[i];
      const bool hi = static_cast<int>(i) == cursor_;
      if (hi) fill(c.all, pad, kRoundCorner * s, style_.candHiliteBack);
      // Labels take the candidate's colour, comments their own unless highlighted (Weasel's fallbacks).
      const UINT32 fg = hi ? style_.candHiliteText : style_.candText;
      text(c.label, c.labelBox, fg);
      text(c.text, c.textBox, fg);
      if (!c.comment.empty()) text(c.comment, c.commentBox, hi ? fg : style_.comment);
    }
    if (!pigBox_.empty() && pig())
      target_->DrawBitmap(pig_, D2D1::RectF(pigBox_.l, pigBox_.t, pigBox_.r, pigBox_.b), 1,
                          D2D1_BITMAP_INTERPOLATION_MODE_LINEAR);
    release(brush);
    if (target_->EndDraw() == D2DERR_RECREATE_TARGET) release(pig_);
  }
  RECT r;
  GetWindowRect(hwnd_, &r);
  POINT src{0, 0}, pos{r.left, r.top};
  SIZE size{w, h};
  BLENDFUNCTION blend{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(hwnd_, screen, &pos, &size, dc, &src, 0, &blend, ULW_ALPHA);
  SelectObject(dc, old);
  if (bitmap) DeleteObject(bitmap);
  DeleteDC(dc);
  ReleaseDC(nullptr, screen);
}

// Below the caret, or above it where the screen ends, as Weasel placed it.
void CandidateWindow::place(const RECT &caret) {
  MONITORINFO mi{sizeof(mi)};
  GetMonitorInfoW(MonitorFromRect(&caret, MONITOR_DEFAULTTONEAREST), &mi);
  const RECT &work = mi.rcWork;
  const int w = static_cast<int>(std::ceil(width_)), h = static_cast<int>(std::ceil(height_));
  int x = std::clamp<int>(caret.left, work.left, std::max<int>(work.left, work.right - w));
  int y = caret.bottom;
  if (y + h > work.bottom) y = std::max<int>(work.top, caret.top - h);
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
}

void CandidateWindow::show(const Reply &reply, bool preeditRow, const RECT &caret) {
  preedit_.clear();
  preeditHighlight_ = -1;
  if (preeditRow) {
    for (const Segment &seg : reply.preedit.segments) {
      if (seg.highlight) preeditHighlight_ = static_cast<int>(preedit_.size());
      preedit_.push_back(utf16(seg.text));
    }
  }
  aux_ = utf16(reply.aux);
  cells_.clear();
  for (size_t i = 0; i < reply.page.items.size(); ++i) {
    Cell c;
    // The core's labels end in Fcitx's space, Rime's as "1 " and Mozc's as "1. "; Weasel showed "%s.".
    if (i < reply.page.labels.size()) {
      c.label = utf16(reply.page.labels[i]);
      while (!c.label.empty() && c.label.back() == L' ') c.label.pop_back();
      if (!c.label.empty() && c.label.back() != L'.') c.label += L".";
    }
    c.text = utf16(reply.page.items[i].text);
    c.comment = utf16(reply.page.items[i].comment);
    cells_.push_back(std::move(c));
  }
  cursor_ = reply.page.cursor;
  if (cells_.empty() && preedit_.empty() && aux_.empty()) return hide();
  if (!create()) return;
  KillTimer(hwnd_, kNoticeTimer);
  if (!styleLoaded_ || !IsWindowVisible(hwnd_)) loadStyle(caret);  // the Configurator's changes, once per showing
  layout();
  place(caret);
  draw();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
}

void CandidateWindow::notice(const std::string &text, const RECT &caret) {
  if (text.empty() || !create()) return;
  loadStyle(caret);
  preedit_ = {utf16(text)};
  preeditHighlight_ = -1;
  aux_.clear();
  cells_.clear();
  layout();
  place(caret);
  draw();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetTimer(hwnd_, kNoticeTimer, kNoticeMs, nullptr);
}

void CandidateWindow::hide() {
  if (!hwnd_) return;
  KillTimer(hwnd_, kNoticeTimer);
  ShowWindow(hwnd_, SW_HIDE);
}

LRESULT CALLBACK CandidateWindow::proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  auto *self = reinterpret_cast<CandidateWindow *>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  switch (msg) {
    case WM_MOUSEACTIVATE: return MA_NOACTIVATE;  // the app keeps the focus
    case WM_TIMER:
      if (self && wParam == kNoticeTimer) self->hide();
      return 0;
    case WM_LBUTTONUP:
      if (self) {
        const float x = static_cast<short>(LOWORD(lParam)), y = static_cast<short>(HIWORD(lParam));
        for (size_t i = 0; i < self->cells_.size(); ++i) {
          const Box &b = self->cells_[i].all;
          if (x >= b.l && x < b.r && y >= b.t && y < b.b) {
            self->service_.select(static_cast<int>(i));
            break;
          }
        }
      }
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

}  // namespace sebtype::win
