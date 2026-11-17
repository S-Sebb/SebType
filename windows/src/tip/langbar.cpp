// SebType on Windows: the input indicator's button. MIT, SebType.
#include "langbar.h"

#include "resource.h"

#include <olectl.h>

#include <string_view>

namespace sebtype::win {
namespace {

constexpr DWORD kCookie = 1;  // one sink at a time
// The taskbar's input indicator shows the button with this id; Windows' headers don't name it.
constexpr GUID kLbiInputMode = {0x2c77a81e, 0x41cc, 0x4178, {0xa3, 0xa7, 0x5f, 0x8a, 0x98, 0x75, 0x68, 0xe6}};

int iconId(std::string_view name) {
  if (name == "zh-a") return IDI_ZH_A;
  if (name == "zh-caps") return IDI_ZH_CAPS;
  if (name == "hira") return IDI_HIRA;
  if (name == "kata") return IDI_KATA;
  if (name == "ja-a") return IDI_JA_A;
  if (name == "ja-caps") return IDI_JA_CAPS;
  if (name == "zh-wait") return IDI_ZH_WAIT;
  if (name == "zh-off") return IDI_ZH_OFF;
  if (name == "hira-wait") return IDI_HIRA_WAIT;
  if (name == "hira-off") return IDI_HIRA_OFF;
  return IDI_ZH;
}

std::wstring title(const Reply &r) { return r.lang == Lang::Japanese ? L"日本語" : L"中文"; }

}  // namespace

STDMETHODIMP LangBarButton::QueryInterface(REFIID riid, void **out) {
  if (riid == IID_IUnknown || riid == IID_ITfLangBarItem || riid == IID_ITfLangBarItemButton) {
    *out = static_cast<ITfLangBarItemButton *>(this);
  } else if (riid == IID_ITfSource) {
    *out = static_cast<ITfSource *>(this);
  } else {
    *out = nullptr;
    return E_NOINTERFACE;
  }
  AddRef();
  return S_OK;
}

STDMETHODIMP_(ULONG) LangBarButton::Release() {
  const long n = --refs_;
  if (!n) delete this;
  return n;
}

STDMETHODIMP LangBarButton::GetInfo(TF_LANGBARITEMINFO *info) {
  info->clsidService = kClsid;
  info->guidItem = kLbiInputMode;
  info->dwStyle = TF_LBI_STYLE_BTN_BUTTON | TF_LBI_STYLE_BTN_MENU | TF_LBI_STYLE_SHOWNINTRAY;
  info->ulSort = 0;
  wcsncpy_s(info->szDescription, title(service_.reply()).c_str(), _TRUNCATE);
  return S_OK;
}

STDMETHODIMP LangBarButton::GetStatus(DWORD *status) {
  *status = 0;
  return S_OK;
}

STDMETHODIMP LangBarButton::GetTooltipString(BSTR *out) {
  *out = SysAllocString(title(service_.reply()).c_str());
  return *out ? S_OK : E_OUTOFMEMORY;
}

STDMETHODIMP LangBarButton::GetText(BSTR *out) { return GetTooltipString(out); }

STDMETHODIMP LangBarButton::OnClick(TfLBIClick click, POINT pt, const RECT *) {
  if (click == TF_LBI_CLK_LEFT) service_.toggleLatin();
  if (click == TF_LBI_CLK_RIGHT) popup(pt);
  return S_OK;
}

// A right-click on Windows' input indicator comes here, and the text service shows the menu itself (as
// Mozc's did): the same items as InitMenu, the language bar's way. The owner is hidden and never
// activated, so the app's text field keeps the keyboard.
void LangBarButton::popup(POINT pt) {
  HMENU menu = CreatePopupMenu();
  const auto &items = service_.reply().menu;
  for (size_t i = 0; i < items.size(); ++i)
    if (items[i].kind == MenuItem::Switch)
      AppendMenuW(menu, MF_STRING | (items[i].checked ? MF_CHECKED : 0), i + 1, utf16(items[i].label).c_str());
  HWND owner = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, L"STATIC", nullptr, WS_POPUP, pt.x, pt.y, 0, 0,
                               nullptr, nullptr, dllInstance, nullptr);
  const UINT id = TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, pt.x, pt.y, owner, nullptr);
  DestroyWindow(owner);
  DestroyMenu(menu);
  if (id) service_.menu(static_cast<int>(id - 1));
}

// The core's menu without its language list, which Windows shows itself: the language's switch.
STDMETHODIMP LangBarButton::InitMenu(ITfMenu *menu) {
  const auto &items = service_.reply().menu;
  for (size_t i = 0; i < items.size(); ++i) {
    if (items[i].kind != MenuItem::Switch) continue;
    const std::wstring label = utf16(items[i].label);
    menu->AddMenuItem(static_cast<UINT>(i), items[i].checked ? TF_LBMENUF_CHECKED : 0, nullptr, nullptr,
                      label.c_str(), static_cast<ULONG>(label.size()), nullptr);
  }
  return S_OK;
}

STDMETHODIMP LangBarButton::OnMenuSelect(UINT id) {
  service_.menu(static_cast<int>(id));
  return S_OK;
}

// At the taskbar's DPI, where it is drawn: a DPI-unaware app's SM_CXSMICON is 16 at any scaling, and the taskbar
// stretched that icon (blurry at 150 %, #275).
STDMETHODIMP LangBarButton::GetIcon(HICON *out) {
  const DPI_AWARENESS_CONTEXT old = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
  const HWND taskbar = FindWindowW(L"Shell_TrayWnd", nullptr);
  const int size = GetSystemMetricsForDpi(SM_CXSMICON, taskbar ? GetDpiForWindow(taskbar) : GetDpiForSystem());
  if (old) SetThreadDpiAwarenessContext(old);
  *out = static_cast<HICON>(LoadImageW(dllInstance, MAKEINTRESOURCEW(iconId(service_.reply().icon)), IMAGE_ICON,
                                       size, size, LR_DEFAULTCOLOR));
  return *out ? S_OK : E_FAIL;
}

STDMETHODIMP LangBarButton::AdviseSink(REFIID riid, IUnknown *sink, DWORD *cookie) {
  if (riid != IID_ITfLangBarItemSink) return CONNECT_E_CANNOTCONNECT;
  if (sink_) return CONNECT_E_ADVISELIMIT;
  if (FAILED(sink->QueryInterface(IID_ITfLangBarItemSink, reinterpret_cast<void **>(&sink_)))) {
    sink_ = nullptr;
    return E_NOINTERFACE;
  }
  *cookie = kCookie;
  return S_OK;
}

STDMETHODIMP LangBarButton::UnadviseSink(DWORD cookie) {
  if (cookie != kCookie || !sink_) return CONNECT_E_NOCONNECTION;
  sink_->Release();
  sink_ = nullptr;
  return S_OK;
}

void LangBarButton::update() {
  if (sink_) sink_->OnUpdate(TF_LBI_ICON | TF_LBI_TEXT | TF_LBI_TOOLTIP);
}

}  // namespace sebtype::win
