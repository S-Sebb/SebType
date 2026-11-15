// SebType on Windows: the language's button in the taskbar's input indicator: its icon by mode (pc/icons), a
// left click for English letters and back (as Weasel and Mozc did), and its menu with the language's switch
// (Windows lists the languages itself). MIT, SebType.
#pragma once

#include "tip.h"

#include <ctfutb.h>

namespace sebtype::win {

class LangBarButton final : public ITfLangBarItemButton, public ITfSource {
 public:
  explicit LangBarButton(TextService &service) : service_(service) {}

  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void **out) override;
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override;

  // ITfLangBarItem
  STDMETHODIMP GetInfo(TF_LANGBARITEMINFO *info) override;
  STDMETHODIMP GetStatus(DWORD *status) override;
  STDMETHODIMP Show(BOOL) override { return E_NOTIMPL; }
  STDMETHODIMP GetTooltipString(BSTR *out) override;

  // ITfLangBarItemButton
  STDMETHODIMP OnClick(TfLBIClick click, POINT pt, const RECT *) override;
  STDMETHODIMP InitMenu(ITfMenu *menu) override;
  STDMETHODIMP OnMenuSelect(UINT id) override;
  STDMETHODIMP GetIcon(HICON *out) override;
  STDMETHODIMP GetText(BSTR *out) override;

  // ITfSource
  STDMETHODIMP AdviseSink(REFIID riid, IUnknown *sink, DWORD *cookie) override;
  STDMETHODIMP UnadviseSink(DWORD cookie) override;

  // The reply changed the icon or the menu.
  void update();

 private:
  void popup(POINT pt);

  TextService &service_;
  std::atomic<long> refs_{1};
  ITfLangBarItemSink *sink_ = nullptr;
};

}  // namespace sebtype::win
