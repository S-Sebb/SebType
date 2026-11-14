// SebType on Windows: the input indicator's button. MIT, SebType.
#include "langbar.h"

#include "resource.h"

#include <olectl.h>

#include <string_view>

namespace sebtype::win {
namespace {

constexpr DWORD kCookie = 1;  // one sink at a time

int iconId(std::string_view name) {
  if (name == "zh-a") return IDI_ZH_A;
  if (name == "zh-caps") return IDI_ZH_CAPS;
  if (name == "hira") return IDI_HIRA;
  if (name == "kata") return IDI_KATA;
  if (name == "ja-a") return IDI_JA_A;
  if (name == "ja-caps") return IDI_JA_CAPS;
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
  info->guidItem = GUID_LBI_INPUTMODE;  // the taskbar's input indicator shows this one
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

STDMETHODIMP LangBarButton::OnClick(TfLBIClick click, POINT, const RECT *) {
  if (click == TF_LBI_CLK_LEFT) service_.toggleLatin();
  return S_OK;
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

STDMETHODIMP LangBarButton::GetIcon(HICON *out) {
  const int size = GetSystemMetrics(SM_CXSMICON);
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
