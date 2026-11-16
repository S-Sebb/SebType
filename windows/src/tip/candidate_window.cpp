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

// weasel.yaml's look, in pixels at 100 % (its layout: candidate_layout.cpp).
constexpr float kHilitePadding = 2, kRoundCorner = 4, kCornerRadius = 4, kBorder = 3;
// The page arrows' chevrons: their height in a text row, and their stroke in the font's size (#276); the
// arrow of a page that doesn't exist is drawn this faint.
constexpr float kChevronHeight = 0.5f, kChevronStroke = 0.12f, kFaint = 0.25f;

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

// The work area of the caret's monitor, where the window has to stay.
RECT workArea(const RECT &caret) {
  MONITORINFO mi{sizeof(mi)};
  GetMonitorInfoW(MonitorFromRect(&caret, MONITOR_DEFAULTTONEAREST), &mi);
  return mi.rcWork;
}

// What stays the same over a word's pages: its pinyin (Rime's doesn't change as it pages); Mozc's shows the
// focused candidate in the segment being converted, so only where that segment is.
std::wstring word(const Preedit &preedit, bool pinyin) {
  std::wstring key;
  for (const Segment &seg : preedit.segments) key += (seg.highlight && !pinyin ? L"\x1" : utf16(seg.text)) + L'\x2';
  return key;
}

}  // namespace

CandidateWindow::~CandidateWindow() {
  if (hwnd_) DestroyWindow(hwnd_);
  release(pig_);
  release(target_);
  release(round_);
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
  const auto round = D2D1::StrokeStyleProperties(D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_ROUND);
  return SUCCEEDED(d2d_->CreateStrokeStyle(&round, nullptr, 0, &round_)) &&
         SUCCEEDED(d2d_->CreateDCRenderTarget(&props, &target_));
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

Box CandidateWindow::measure(const std::wstring &text, float x, float y) {
  DWRITE_TEXT_METRICS m{};
  if (IDWriteTextLayout *layout = textLayout(text)) {
    layout->GetMetrics(&m);
    layout->Release();
  }
  return {x, y, x + std::ceil(m.widthIncludingTrailingWhitespace), y + std::ceil(m.height)};
}

void CandidateWindow::layout(const RECT &caret) {
  const RECT work = workArea(caret);
  CandidateLayout &l = layout_;
  l.vertical = style_.vertical, l.picnic = style_.picnic, l.scale = style_.scale;
  l.maxWidth = static_cast<float>(work.right - work.left);
  l.run([this](const std::wstring &text, float x, float y) { return measure(text, x, y); });
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
  const CandidateLayout &l = layout_;
  const int w = static_cast<int>(std::ceil(l.width)), h = static_cast<int>(std::ceil(l.height));
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
        D2D1::RectF(border / 2, border / 2, l.width - border / 2, l.height - border / 2), kCornerRadius * s,
        kCornerRadius * s);
    color(style_.back);
    target_->FillRoundedRectangle(card, brush);
    color(style_.border);
    target_->DrawRoundedRectangle(card, brush, border);

    for (size_t i = 0; i < l.preedit.size(); ++i) {
      const bool hi = static_cast<int>(i) == preeditHighlight_;
      if (hi) fill(l.preeditBoxes[i], pad, kRoundCorner * s, style_.hiliteBack);
      text(l.preedit[i], l.preeditBoxes[i], hi ? style_.hiliteText : style_.text);
    }
    if (!l.aux.empty()) text(l.aux, l.auxBox, style_.text);
    for (size_t i = 0; i < l.cells.size(); ++i) {
      const auto &c = l.cells[i];
      const bool hi = static_cast<int>(i) == cursor_;
      if (hi) fill(c.all, pad, kRoundCorner * s, style_.candHiliteBack);
      // Labels take the candidate's colour, comments their own unless highlighted (Weasel's fallbacks).
      const UINT32 fg = hi ? style_.candHiliteText : style_.candText;
      text(c.label, c.labelBox, fg);
      text(c.text, c.textBox, fg);
      if (!c.comment.empty()) text(c.comment, c.commentBox, hi ? fg : style_.comment);
    }
    // ‹ and ›: chevrons in the text's colour, faint where there is no page.
    auto chevron = [&](const Box &b, bool right, bool there) {
      if (b.empty()) return;
      const float half = std::round((b.b - b.t) * kChevronHeight / 2), cx = (b.l + b.r) / 2,
                  cy = (b.t + b.b) / 2, dx = half / 2 * (right ? 1 : -1);
      brush->SetColor(D2D1::ColorF(style_.text, there ? 1 : kFaint));
      const float stroke = std::max(1.5f, style_.fontPx * kChevronStroke);
      target_->DrawLine(D2D1::Point2F(cx - dx, cy - half), D2D1::Point2F(cx + dx, cy), brush, stroke, round_);
      target_->DrawLine(D2D1::Point2F(cx + dx, cy), D2D1::Point2F(cx - dx, cy + half), brush, stroke, round_);
    };
    chevron(l.prevBox, false, l.hasPrev);
    chevron(l.nextBox, true, l.hasNext);
    if (!l.pigBox.empty() && pig())
      target_->DrawBitmap(pig_, D2D1::RectF(l.pigBox.l, l.pigBox.t, l.pigBox.r, l.pigBox.b), 1,
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

// Below the caret, or above it where the screen ends, as Weasel placed it; within the monitor's work area.
void CandidateWindow::place(const RECT &caret) {
  const RECT work = workArea(caret);
  const int w = static_cast<int>(std::ceil(layout_.width)), h = static_cast<int>(std::ceil(layout_.height));
  const int x = std::clamp<int>(caret.left, work.left, std::max<int>(work.left, work.right - w));
  int y = caret.bottom;
  if (y + h > work.bottom) y = caret.top - h;
  y = std::clamp<int>(y, work.top, std::max<int>(work.top, work.bottom - h));
  SetWindowPos(hwnd_, HWND_TOPMOST, x, y, w, h, SWP_NOACTIVATE);
}

void CandidateWindow::show(const Reply &reply, bool preeditRow, const RECT &caret) {
  CandidateLayout &l = layout_;
  l.preedit.clear();
  preeditHighlight_ = -1;
  if (preeditRow) {
    for (const Segment &seg : reply.preedit.segments) {
      if (seg.highlight) preeditHighlight_ = static_cast<int>(l.preedit.size());
      l.preedit.push_back(utf16(seg.text));
    }
  }
  l.aux = utf16(reply.aux);
  l.cells.clear();
  for (size_t i = 0; i < reply.page.items.size(); ++i) {
    CandidateLayout::Cell c;
    // The core's labels end in Fcitx's space, Rime's as "1 " and Mozc's as "1. "; Weasel showed "%s.".
    if (i < reply.page.labels.size()) {
      c.label = utf16(reply.page.labels[i]);
      while (!c.label.empty() && c.label.back() == L' ') c.label.pop_back();
      if (!c.label.empty() && c.label.back() != L'.') c.label += L".";
    }
    c.text = utf16(reply.page.items[i].text);
    c.comment = utf16(reply.page.items[i].comment);
    l.cells.push_back(std::move(c));
  }
  l.hasPrev = reply.page.hasPrev, l.hasNext = reply.page.hasNext;
  cursor_ = reply.page.cursor;
  if (l.cells.empty() && l.preedit.empty() && l.aux.empty()) return hide();
  if (!create()) return;
  KillTimer(hwnd_, kNoticeTimer);
  const bool shown = IsWindowVisible(hwnd_);
  if (!styleLoaded_ || !shown) loadStyle(caret);  // the Configurator's changes, once per showing
  std::wstring w = word(reply.preedit, preeditRow);
  l.keepWidth = shown && w == word_ ? l.width : 0;
  word_ = std::move(w);
  layout(caret);
  place(caret);
  draw();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
}

void CandidateWindow::notice(const std::string &text, const RECT &caret) {
  if (text.empty() || !create()) return;
  loadStyle(caret);
  CandidateLayout &l = layout_;
  l.preedit = {utf16(text)};
  preeditHighlight_ = -1;
  l.aux.clear();
  l.cells.clear();
  l.hasPrev = l.hasNext = false;
  l.keepWidth = 0;
  word_.clear();
  layout(caret);
  place(caret);
  draw();
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  SetTimer(hwnd_, kNoticeTimer, kNoticeMs, nullptr);
}

void CandidateWindow::hide() {
  if (!hwnd_) return;
  KillTimer(hwnd_, kNoticeTimer);
  ShowWindow(hwnd_, SW_HIDE);
  word_.clear();
  wheel_ = 0;
}

void CandidateWindow::page(bool next) {
  if (next ? layout_.hasNext : layout_.hasPrev) service_.page(next);
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
        const int at = self->layout_.hit(static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam)));
        if (at >= 0) self->service_.select(at);
        else if (at != CandidateLayout::kNone) self->page(at == CandidateLayout::kNext);
      }
      return 0;
    // Windows sends the wheel to the window under the mouse (its default "scroll inactive windows"). A notch
    // down is the next page; a touchpad's smaller turns add up to one.
    case WM_MOUSEWHEEL:
      if (self) {
        self->wheel_ += GET_WHEEL_DELTA_WPARAM(wParam);
        while (self->wheel_ >= WHEEL_DELTA || self->wheel_ <= -WHEEL_DELTA) {
          const bool next = self->wheel_ < 0;
          self->wheel_ += next ? WHEEL_DELTA : -WHEEL_DELTA;
          self->page(next);
        }
      }
      return 0;
  }
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

}  // namespace sebtype::win
