// SebType on Windows: an edit session that runs a function, the only way a text service may change or read
// the app's text. MIT, SebType.
#pragma once

#include "tip.h"

#include <functional>

namespace sebtype::win {

class EditSession final : public ITfEditSession {
 public:
  explicit EditSession(std::function<HRESULT(TfEditCookie)> fn) : fn_(std::move(fn)) {}

  STDMETHODIMP QueryInterface(REFIID riid, void **out) override {
    if (riid == IID_IUnknown || riid == IID_ITfEditSession) {
      *out = static_cast<ITfEditSession *>(this);
      AddRef();
      return S_OK;
    }
    *out = nullptr;
    return E_NOINTERFACE;
  }
  STDMETHODIMP_(ULONG) AddRef() override { return ++refs_; }
  STDMETHODIMP_(ULONG) Release() override {
    const long n = --refs_;
    if (!n) delete this;
    return n;
  }
  STDMETHODIMP DoEditSession(TfEditCookie ec) override { return fn_(ec); }

 private:
  std::function<HRESULT(TfEditCookie)> fn_;
  std::atomic<long> refs_{1};
};

// Synchronous when the app allows it (from a key handler), else as soon as the app can; to read only, a lock a
// read-only field grants too.
template <class Fn>
HRESULT editSession(ITfContext *context, TfClientId clientId, Fn fn, bool sync = true, DWORD lock = TF_ES_READWRITE) {
  auto *session = new EditSession(fn);
  HRESULT result = E_FAIL;
  const HRESULT hr =
      context->RequestEditSession(clientId, session, (sync ? TF_ES_SYNC : TF_ES_ASYNCDONTCARE) | lock, &result);
  session->Release();
  return FAILED(hr) ? hr : result;
}

}  // namespace sebtype::win
