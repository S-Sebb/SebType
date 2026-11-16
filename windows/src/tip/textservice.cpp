// SebType on Windows: the text service's life in an app: activation, focus, the language profiles, keys,
// and the display attributes of Japanese's inline composition. MIT, SebType.
#include "candidate_window.h"
#include "edit_session.h"
#include "langbar.h"

#include <inputscope.h>

#include <filesystem>

namespace sebtype::win {
namespace {

// inputscope.h's GUIDs, here so no import library needs to have them.
constexpr GUID kPropInputScope = {0x1713dd5a, 0x68e7, 0x4a5b, {0x9a, 0xf6, 0x59, 0x2a, 0x59, 0x5c, 0x77, 0x8d}};
constexpr GUID kIidInputScope = {0xfde1eaee, 0x6924, 0x4cdf, {0x91, 0xe7, 0xda, 0x38, 0xcf, 0xf5, 0x55, 0x9d}};

// --- Keys: Windows' virtual keys as the X11 keysyms the core takes ---

uint32_t special(UINT vk, bool extended, UINT scan) {
  switch (vk) {
    case VK_BACK: return 0xff08;
    case VK_TAB: return 0xff09;
    case VK_RETURN: return extended ? 0xff8d : 0xff0d;  // KP_Enter
    case VK_ESCAPE: return 0xff1b;
    case VK_SPACE: return 0x20;
    case VK_DELETE: return 0xffff;
    case VK_HOME: return 0xff50;
    case VK_LEFT: return 0xff51;
    case VK_UP: return 0xff52;
    case VK_RIGHT: return 0xff53;
    case VK_DOWN: return 0xff54;
    case VK_PRIOR: return 0xff55;
    case VK_NEXT: return 0xff56;
    case VK_END: return 0xff57;
    case VK_INSERT: return 0xff63;
    case VK_SHIFT: return MapVirtualKeyW(scan, MAPVK_VSC_TO_VK_EX) == VK_RSHIFT ? 0xffe2 : 0xffe1;
    case VK_LSHIFT: return 0xffe1;
    case VK_RSHIFT: return 0xffe2;
    case VK_CONTROL: return extended ? 0xffe4 : 0xffe3;
    case VK_LCONTROL: return 0xffe3;
    case VK_RCONTROL: return 0xffe4;
    case VK_MENU: return extended ? 0xffea : 0xffe9;
    case VK_LMENU: return 0xffe9;
    case VK_RMENU: return 0xffea;
    case VK_CAPITAL: return 0xffe5;
    case VK_LWIN: return 0xffeb;
    case VK_RWIN: return 0xffec;
    case VK_MULTIPLY: return 0xffaa;
    case VK_ADD: return 0xffab;
    case VK_SUBTRACT: return 0xffad;
    case VK_DECIMAL: return 0xffae;
    case VK_DIVIDE: return 0xffaf;
  }
  if (vk >= VK_NUMPAD0 && vk <= VK_NUMPAD9) return 0xffb0 + (vk - VK_NUMPAD0);
  if (vk >= VK_F1 && vk <= VK_F24) return 0xffbe + (vk - VK_F1);
  return 0;
}

// The modifier bit a modifier key sets, so the key's own press can leave it out as X11 does.
uint32_t ownMod(uint32_t sym) {
  if (sym == 0xffe1 || sym == 0xffe2) return mod::Shift;
  if (sym == 0xffe3 || sym == 0xffe4) return mod::Ctrl;
  if (sym == 0xffe9 || sym == 0xffea) return mod::Alt;
  if (sym == 0xffeb || sym == 0xffec) return mod::Super;
  return 0;
}

// --- Display attributes: what is typed (dotted) and the segment being converted (bold), as Mozc drew them ---

class AttributeInfo final : public ITfDisplayAttributeInfo {
 public:
  AttributeInfo(const GUID &guid, const wchar_t *name, TF_DA_LINESTYLE line, bool bold) : guid_(guid), name_(name) {
    attr_.lsStyle = line;
    attr_.fBoldLine = bold;
    attr_.bAttr = bold ? TF_ATTR_TARGET_CONVERTED : TF_ATTR_INPUT;
  }
  STDMETHODIMP QueryInterface(REFIID riid, void **out) override {
    if (riid == IID_IUnknown || riid == IID_ITfDisplayAttributeInfo) {
      *out = this;
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
  STDMETHODIMP GetGUID(GUID *out) override {
    *out = guid_;
    return S_OK;
  }
  STDMETHODIMP GetDescription(BSTR *out) override {
    *out = SysAllocString(name_);
    return *out ? S_OK : E_OUTOFMEMORY;
  }
  STDMETHODIMP GetAttributeInfo(TF_DISPLAYATTRIBUTE *out) override {
    *out = attr_;
    return S_OK;
  }
  STDMETHODIMP SetAttributeInfo(const TF_DISPLAYATTRIBUTE *) override { return E_NOTIMPL; }
  STDMETHODIMP Reset() override { return S_OK; }

 private:
  GUID guid_;
  const wchar_t *name_;
  TF_DISPLAYATTRIBUTE attr_{};
  std::atomic<long> refs_{1};
};

ITfDisplayAttributeInfo *attributeInfo(int i) {
  if (i == 0) return new AttributeInfo(kAttrInput, L"SebType input", TF_LS_DOT, false);
  if (i == 1) return new AttributeInfo(kAttrTarget, L"SebType converted", TF_LS_SOLID, true);
  return nullptr;
}

class AttributeEnum final : public IEnumTfDisplayAttributeInfo {
 public:
  explicit AttributeEnum(int next = 0) : next_(next) {}
  STDMETHODIMP QueryInterface(REFIID riid, void **out) override {
    if (riid == IID_IUnknown || riid == IID_IEnumTfDisplayAttributeInfo) {
      *out = this;
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
  STDMETHODIMP Clone(IEnumTfDisplayAttributeInfo **out) override {
    *out = new AttributeEnum(next_);
    return S_OK;
  }
  STDMETHODIMP Next(ULONG count, ITfDisplayAttributeInfo **out, ULONG *fetched) override {
    ULONG n = 0;
    for (; n < count; ++n) {
      out[n] = attributeInfo(next_);
      if (!out[n]) break;
      ++next_;
    }
    if (fetched) *fetched = n;
    return n == count ? S_OK : S_FALSE;
  }
  STDMETHODIMP Reset() override {
    next_ = 0;
    return S_OK;
  }
  STDMETHODIMP Skip(ULONG count) override {
    next_ += static_cast<int>(count);
    return next_ <= 2 ? S_OK : S_FALSE;
  }

 private:
  int next_;
  std::atomic<long> refs_{1};
};

// The server next to this DLL, or one folder up from the 32-bit one in x86\.
std::filesystem::path serverPath() {
  wchar_t p[MAX_PATH];
  GetModuleFileNameW(dllInstance, p, MAX_PATH);
  const auto dir = std::filesystem::path(p).parent_path();
  const auto here = dir / L"sebtype-server.exe";
  return std::filesystem::exists(here) ? here : dir.parent_path() / L"sebtype-server.exe";
}

}  // namespace

TextService::TextService() { ++dllRefs; }

TextService::~TextService() { --dllRefs; }

STDMETHODIMP TextService::QueryInterface(REFIID riid, void **out) {
  if (riid == IID_IUnknown || riid == IID_ITfTextInputProcessor || riid == IID_ITfTextInputProcessorEx)
    *out = static_cast<ITfTextInputProcessorEx *>(this);
  else if (riid == IID_ITfThreadMgrEventSink)
    *out = static_cast<ITfThreadMgrEventSink *>(this);
  else if (riid == IID_ITfKeyEventSink)
    *out = static_cast<ITfKeyEventSink *>(this);
  else if (riid == IID_ITfCompositionSink)
    *out = static_cast<ITfCompositionSink *>(this);
  else if (riid == IID_ITfDisplayAttributeProvider)
    *out = static_cast<ITfDisplayAttributeProvider *>(this);
  else if (riid == IID_ITfInputProcessorProfileActivationSink)
    *out = static_cast<ITfInputProcessorProfileActivationSink *>(this);
  else {
    *out = nullptr;
    return E_NOINTERFACE;
  }
  AddRef();
  return S_OK;
}

STDMETHODIMP_(ULONG) TextService::AddRef() { return ++refs_; }

STDMETHODIMP_(ULONG) TextService::Release() {
  const long n = --refs_;
  if (!n) delete this;
  return n;
}

// --- Activation ---

STDMETHODIMP TextService::Activate(ITfThreadMgr *threadMgr, TfClientId clientId) {
  return ActivateEx(threadMgr, clientId, 0);
}

STDMETHODIMP TextService::ActivateEx(ITfThreadMgr *threadMgr, TfClientId clientId, DWORD) {
  threadMgr_ = threadMgr;
  threadMgr_->AddRef();
  clientId_ = clientId;

  ITfSource *source = nullptr;
  if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void **>(&source)))) {
    source->AdviseSink(IID_ITfThreadMgrEventSink, static_cast<ITfThreadMgrEventSink *>(this), &threadMgrCookie_);
    source->AdviseSink(IID_ITfInputProcessorProfileActivationSink,
                       static_cast<ITfInputProcessorProfileActivationSink *>(this), &activationCookie_);
    source->Release();
  }
  ITfKeystrokeMgr *keys = nullptr;
  if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keys)))) {
    keys->AdviseKeyEventSink(clientId_, static_cast<ITfKeyEventSink *>(this), TRUE);
    keys->Release();
  }
  ITfCategoryMgr *categories = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_TF_CategoryMgr, nullptr, CLSCTX_INPROC_SERVER, IID_ITfCategoryMgr,
                                 reinterpret_cast<void **>(&categories)))) {
    categories->RegisterGUID(kAttrInput, &attrInput_);
    categories->RegisterGUID(kAttrTarget, &attrTarget_);
    categories->Release();
  }
  window_ = std::make_unique<CandidateWindow>(*this);
  button_ = new LangBarButton(*this);
  ITfLangBarItemMgr *items = nullptr;
  if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfLangBarItemMgr, reinterpret_cast<void **>(&items)))) {
    items->AddItem(button_);
    items->Release();
  }
  setOpen();

  // The profile Windows activated us with: 中文 or 日本語.
  ITfInputProcessorProfileMgr *profiles = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                 IID_ITfInputProcessorProfileMgr, reinterpret_cast<void **>(&profiles)))) {
    TF_INPUTPROCESSORPROFILE p{};
    if (SUCCEEDED(profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD, &p)) && p.clsid == kClsid)
      setLanguage(p.guidProfile);
    profiles->Release();
  }
  ITfDocumentMgr *focused = nullptr;
  if (SUCCEEDED(threadMgr_->GetFocus(&focused)) && focused) {
    focus(focused);
    focused->Release();
  }
  return S_OK;
}

STDMETHODIMP TextService::Deactivate() {
  if (composition_ && context_) {
    editSession(context_, clientId_, [this](TfEditCookie ec) { return endComposition(ec, context_); });
  }
  if (context_) {
    send({Op::FocusOut});
    context_->Release();
    context_ = nullptr;
  }
  window_.reset();
  if (button_) {
    ITfLangBarItemMgr *items = nullptr;
    if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfLangBarItemMgr, reinterpret_cast<void **>(&items)))) {
      items->RemoveItem(button_);
      items->Release();
    }
    button_->Release();
    button_ = nullptr;
  }
  ITfKeystrokeMgr *keys = nullptr;
  if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfKeystrokeMgr, reinterpret_cast<void **>(&keys)))) {
    keys->UnadviseKeyEventSink(clientId_);
    keys->Release();
  }
  ITfSource *source = nullptr;
  if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfSource, reinterpret_cast<void **>(&source)))) {
    source->UnadviseSink(threadMgrCookie_);
    source->UnadviseSink(activationCookie_);
    source->Release();
  }
  threadMgrCookie_ = activationCookie_ = TF_INVALID_COOKIE;
  threadMgr_->Release();
  threadMgr_ = nullptr;
  clientId_ = TF_CLIENTID_NULL;
  return S_OK;
}

// Windows' "IME on": the input indicator shows the button's icon, not a crossed-out one.
void TextService::setOpen() {
  ITfCompartmentMgr *mgr = nullptr;
  ITfCompartment *open = nullptr;
  if (SUCCEEDED(threadMgr_->QueryInterface(IID_ITfCompartmentMgr, reinterpret_cast<void **>(&mgr))) &&
      SUCCEEDED(mgr->GetCompartment(GUID_COMPARTMENT_KEYBOARD_OPENCLOSE, &open))) {
    VARIANT v;
    v.vt = VT_I4;
    v.lVal = 1;
    open->SetValue(clientId_, &v);
  }
  if (open) open->Release();
  if (mgr) mgr->Release();
}

STDMETHODIMP TextService::OnActivated(DWORD profileType, LANGID, REFCLSID clsid, REFGUID, REFGUID profile, HKL,
                                      DWORD flags) {
  if (profileType == TF_PROFILETYPE_INPUTPROCESSOR && clsid == kClsid && (flags & TF_IPSINK_FLAG_ACTIVE))
    setLanguage(profile);
  return S_OK;
}

void TextService::setLanguage(REFGUID profile) {
  const Lang lang = profile == kProfileJa ? Lang::Japanese : Lang::Chinese;
  if (composition_ && context_ && lang != lang_)
    editSession(context_, clientId_, [this](TfEditCookie ec) { return endComposition(ec, context_); });
  lang_ = lang;
  Request q{Op::Language};
  q.lang = lang;
  if (!send(q)) {  // no server: the button still shows the language
    reply_ = {};
    reply_.lang = lang;
    reply_.icon = lang == Lang::Japanese ? "hira" : "zh";
  }
  if (window_) window_->hide();
  if (button_) button_->update();
}

// The language of the thread's keyboard layout, which Windows switches with the profile. ActivateEx can read
// the thread's previous SebType profile as the active one, and the activation notice for the new one can
// come before our sink is there (#190): keys then went to the other language.
void TextService::followLayout() {
  const WORD lang = PRIMARYLANGID(LOWORD(reinterpret_cast<UINT_PTR>(GetKeyboardLayout(0))));
  if (lang == LANG_JAPANESE && lang_ != Lang::Japanese) setLanguage(kProfileJa);
  if (lang == LANG_CHINESE && lang_ != Lang::Chinese) setLanguage(kProfileZh);
}

// --- Focus ---

STDMETHODIMP TextService::OnSetFocus(ITfDocumentMgr *focused, ITfDocumentMgr *) {
  focus(focused);
  return S_OK;
}

void TextService::focus(ITfDocumentMgr *focused) {
  // What was being typed is dropped, as on Linux (the core's focusOut).
  if (context_) {
    if (composition_)
      editSession(context_, clientId_, [this](TfEditCookie ec) { return endComposition(ec, context_); }, false);
    send({Op::FocusOut});
    context_->Release();
    context_ = nullptr;
  }
  if (window_) window_->hide();
  password_ = Password::Unknown;
  if (focused && SUCCEEDED(focused->GetTop(&context_)) && context_) {
    Request q{Op::FocusIn};
    q.lang = lang_;
    send(q);
  }
  if (button_) button_->update();
}

// The input scope of the focused field: password fields get the keys untouched.
bool TextService::password(ITfContext *context) {
  if (password_ != Password::Unknown) return password_ == Password::Yes;
  password_ = Password::No;
  ITfReadOnlyProperty *prop = nullptr;
  const GUID *props[] = {&kPropInputScope};
  if (FAILED(context->TrackProperties(props, 1, nullptr, 0, &prop))) return false;
  editSession(
      context, clientId_,
      [&](TfEditCookie ec) {
        TF_SELECTION sel{};
        ULONG n = 0;
        if (FAILED(context->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &n)) || !n) return S_OK;
        VARIANT v;
        VariantInit(&v);
        if (SUCCEEDED(prop->GetValue(ec, sel.range, &v)) && v.vt == VT_UNKNOWN && v.punkVal) {
          ITfInputScope *scope = nullptr;
          if (SUCCEEDED(v.punkVal->QueryInterface(kIidInputScope, reinterpret_cast<void **>(&scope)))) {
            InputScope *scopes = nullptr;
            UINT count = 0;
            if (SUCCEEDED(scope->GetInputScopes(&scopes, &count))) {
              for (UINT i = 0; i < count; ++i)
                if (scopes[i] == IS_PASSWORD) password_ = Password::Yes;
              CoTaskMemFree(scopes);
            }
            scope->Release();
          }
        }
        VariantClear(&v);
        sel.range->Release();
        return S_OK;
      },
      true);
  prop->Release();
  return password_ == Password::Yes;
}

// --- Keys ---

bool TextService::key(WPARAM wParam, LPARAM lParam, bool release, Key &out) {
  const UINT vk = static_cast<UINT>(wParam), scan = (lParam >> 16) & 0xff;
  const bool extended = (lParam >> 24) & 1;
  if (vk == VK_PROCESSKEY || vk == VK_PACKET) return false;
  BYTE state[256];
  if (!GetKeyboardState(state)) return false;
  uint32_t mods = 0;
  if (state[VK_SHIFT] & 0x80) mods |= mod::Shift;
  if (state[VK_CONTROL] & 0x80) mods |= mod::Ctrl;
  if (state[VK_MENU] & 0x80) mods |= mod::Alt;
  // Keys with Win held are Windows' own shortcuts: Win+Space switches the input method itself, and the
  // core's own Win+Space switch would switch a second time.
  if ((state[VK_LWIN] | state[VK_RWIN]) & 0x80) return false;
  if (state[VK_CAPITAL] & 1) mods |= mod::Lock;
  if (vk == VK_CAPITAL && !release) mods ^= mod::Lock;  // the state before this press, as X11 says it

  uint32_t sym = special(vk, extended, scan);
  // Windows' Japanese keyboard layer hands Alt+` to the text service as the Kanji key (Hankaku/Zenkaku,
  // or its VK_DBE_ forms 0xf3/0xf4), as Mozc's keyevent_handler notes; SebType's Alt+` is the grave key.
  if (!sym && (mods & mod::Alt) && (vk == VK_KANJI || vk == 0xf3 || vk == 0xf4)) sym = '`';
  if (!sym) {
    // The character the layout gives with Shift and Caps Lock, without Ctrl and Alt: Ctrl+Shift+F is F.
    state[VK_CONTROL] = state[VK_LCONTROL] = state[VK_RCONTROL] = 0;
    state[VK_MENU] = state[VK_LMENU] = state[VK_RMENU] = 0;
    wchar_t ch[4];
    // 0x4: leaves the keyboard state (dead keys) alone.
    if (ToUnicodeEx(vk, scan, state, ch, 4, 0x4, GetKeyboardLayout(0)) != 1) return false;
    sym = ch[0] < 0x100 ? ch[0] : 0x01000000 | ch[0];
  }
  if (const uint32_t own = ownMod(sym)) mods = release ? mods | own : mods & ~own;
  out = {sym, mods, release};
  return true;
}

bool TextService::send(const Request &request) {
  if (call(request, reply_)) return true;
  if (GetLastError() == ERROR_TIMEOUT) return false;  // a server that took the key but hangs
  // An app UAC elevated (Setup, an admin console) starts none: the server would be elevated too, and out of
  // reach of the person's other apps. It uses the one they start.
  static const bool elevated = [] {
    HANDLE token = nullptr;
    TOKEN_ELEVATION_TYPE type = TokenElevationTypeDefault;
    DWORD n = 0;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
      GetTokenInformation(token, TokenElevationType, &type, sizeof(type), &n);
      CloseHandle(token);
    }
    return type == TokenElevationTypeFull;
  }();
  if (elevated) return false;
  // No server: start it (Windows' Run key starts it at logon; this is for after it stopped), then wait a
  // little for its pipe. Not again for a while, so a server that can't start doesn't slow every key.
  const DWORD now = GetTickCount();
  if (serverStarted_ && now - serverStarted_ < 10000) return false;
  // SebType is being uninstalled (the uninstaller's mark): its files are about to go.
  if (GetFileAttributesW((serverPath().parent_path() / L"uninstalling").c_str()) != INVALID_FILE_ATTRIBUTES)
    return false;
  serverStarted_ = now;
  STARTUPINFOW si{sizeof(si)};
  PROCESS_INFORMATION pi{};
  std::wstring cmd = L"\"" + serverPath().wstring() + L"\"";
  if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW | DETACHED_PROCESS, nullptr,
                      nullptr, &si, &pi))
    return false;
  CloseHandle(pi.hThread);
  CloseHandle(pi.hProcess);
  for (int i = 0; i < 60; ++i) {
    Sleep(50);
    if (call(request, reply_)) return true;
  }
  return false;
}

void TextService::apply(ITfContext *context) {
  if (context) editSession(context, clientId_, [this, context](TfEditCookie ec) { return update(ec, context); }, false);
  if (button_) button_->update();
}

// The core sees each key once: OnTestKeyDown asks it and keeps the answer for OnKeyDown, as Weasel did.
bool TextService::keyEvent(ITfContext *context, WPARAM wParam, LPARAM lParam, bool release, bool test,
                           BOOL *eaten) {
  *eaten = FALSE;
  if (!test && tested_.pending && tested_.wParam == wParam && tested_.release == release) {
    tested_.pending = false;
    *eaten = tested_.eaten;
    return true;
  }
  tested_.pending = false;
  if (!context || password(context)) return true;
  followLayout();
  Request q{Op::Key};
  q.lang = lang_;
  if (!key(wParam, lParam, release, q.key) || !send(q)) return true;
  *eaten = reply_.taken;
  if (test) tested_ = {wParam, release, reply_.taken, true};
  apply(context);
  return true;
}

STDMETHODIMP TextService::OnTestKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
  keyEvent(context, wParam, lParam, false, true, eaten);
  return S_OK;
}

STDMETHODIMP TextService::OnKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
  keyEvent(context, wParam, lParam, false, false, eaten);
  return S_OK;
}

STDMETHODIMP TextService::OnTestKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
  keyEvent(context, wParam, lParam, true, true, eaten);
  return S_OK;
}

STDMETHODIMP TextService::OnKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) {
  keyEvent(context, wParam, lParam, true, false, eaten);
  return S_OK;
}

// --- The window's clicks and wheel, and the button's picks ---

void TextService::select(int indexOnPage) {
  Request q{Op::Select};
  q.index = indexOnPage;
  if (send(q)) apply(context_);
}

void TextService::page(bool next) {
  Request q{Op::Page};
  q.next = next;
  if (send(q)) apply(context_);
}

void TextService::menu(int index) {
  Request q{Op::Menu};
  q.index = index;
  if (send(q)) apply(context_);
}

void TextService::toggleLatin() {
  if (send({Op::Latin})) apply(context_);
}

// --- The app ended the composition (a click elsewhere in the text, say): the typing is dropped ---

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie, ITfComposition *composition) {
  if (composition == composition_) {
    composition_->Release();
    composition_ = nullptr;
    send({Op::FocusOut});
    if (window_) window_->hide();
  }
  return S_OK;
}

// --- Display attributes ---

STDMETHODIMP TextService::EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo **out) {
  *out = new AttributeEnum();
  return S_OK;
}

STDMETHODIMP TextService::GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo **out) {
  *out = guid == kAttrInput ? attributeInfo(0) : guid == kAttrTarget ? attributeInfo(1) : nullptr;
  return *out ? S_OK : E_INVALIDARG;
}

}  // namespace sebtype::win
