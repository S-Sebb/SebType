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

// The app's calls to the server (pipe.h): its threads share it.
Guarded server;

// The text service whose readiness timer runs on this thread: one per thread, the focused one.
thread_local TextService *watching = nullptr;

bool notReady(const std::string &icon) { return icon.ends_with("-wait") || icon.ends_with("-off"); }

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
  leaving_ = false;

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
  leaving_ = true;
  if (composition_ && context_) {
    editSession(context_, clientId_, [this](TfEditCookie ec) { return endComposition(ec, context_); });
  }
  if (context_) {
    send({Op::FocusOut});
    context_->Release();
    context_ = nullptr;
  }
  stopWatching();
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

// Switching to another keyboard drops what was being typed (the user's choice in #301). TSF can end the
// composition before Deactivate and before the next profile's notice (seen on TCSBackEnd), so the signs are
// our profile going inactive, Deactivate, or another keyboard already active (OnCompositionTerminated). Our
// other language comes active right after its notice, and the next reply clears the flag anyway.
STDMETHODIMP TextService::OnActivated(DWORD profileType, LANGID, REFCLSID clsid, REFGUID, REFGUID profile, HKL,
                                      DWORD flags) {
  if (profileType != TF_PROFILETYPE_INPUTPROCESSOR || clsid != kClsid) return S_OK;
  leaving_ = !(flags & TF_IPSINK_FLAG_ACTIVE);
  if (!leaving_) setLanguage(profile);
  return S_OK;
}

void TextService::setLanguage(REFGUID profile) {
  const Lang lang = profile == kProfileJa ? Lang::Japanese : Lang::Chinese;
  const bool switched = lang != lang_;
  if (switched) warned_ = false;  // the popup says it for each language
  lang_ = lang;
  Request q{Op::Language};
  q.lang = lang;
  if (!send(q)) {  // no server: the button shows the language, unavailable
    reply_ = {};
    reply_.lang = lang;
    reply_.icon = notReadyIcon(lang, Readiness::Unavailable);
  }
  // Between 中 and 日 what was being typed goes in as on focus loss (#301): the core's switch commits it,
  // and it replaces the composition. Switching to another input method comes as Deactivate instead, which drops it.
  if (switched && context_) typeIn(utf16(std::exchange(reply_.commit, {})));
  if (window_) window_->hide();
  if (button_) button_->update();
  watchReadiness();  // a switch to 中文 while Rime deploys is grey until it is done, with no key typed
}

// Whether one of SebType's profiles is still the thread's keyboard (not while another is being activated).
bool TextService::active() {
  bool ours = true;
  ITfInputProcessorProfileMgr *profiles = nullptr;
  if (SUCCEEDED(CoCreateInstance(CLSID_TF_InputProcessorProfiles, nullptr, CLSCTX_INPROC_SERVER,
                                 IID_ITfInputProcessorProfileMgr, reinterpret_cast<void **>(&profiles)))) {
    TF_INPUTPROCESSORPROFILE p{};
    if (SUCCEEDED(profiles->GetActiveProfile(GUID_TFCAT_TIP_KEYBOARD, &p))) ours = p.clsid == kClsid;
    profiles->Release();
  }
  return ours;
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

// The thread's keyboard focus: only the app in front watches whether its language is ready again.
STDMETHODIMP TextService::OnSetFocus(BOOL foreground) {
  if (foreground) watchReadiness();
  else stopWatching();
  return S_OK;
}

void TextService::focus(ITfDocumentMgr *focused) {
  // What was being typed goes into the field it was typed in (#277), as Microsoft's IMEs and Mozc do: the
  // core gives it on FocusOut (pinyin as its letters, Japanese as converted), and it replaces the composition.
  if (context_) {
    std::wstring typed;
    if (send({Op::FocusOut})) typed = utf16(std::exchange(reply_.commit, {}));
    if (leaving_) typed.clear();
    typeIn(typed);
    context_->Release();
    context_ = nullptr;
  }
  if (window_) window_->hide();
  field_ = Field::Unknown;
  stopWatching();
  if (focused && SUCCEEDED(focused->GetTop(&context_)) && context_) {
    Request q{Op::FocusIn};
    q.lang = lang_;
    q.learning = field(context_) != Field::Private;
    send(q);
    watchReadiness();
  }
  if (button_) button_->update();
}

// IS_PRIVATE is what browsers set in private windows: Chromium's (Chrome, Edge) for incognito and guest
// windows and for password fields, Firefox's for private windows, beside the field's own scopes. Asked at
// focus, so the core knows before the first key; when the app can't answer then, asked again at each key.
// The app's text store gives it as an attribute, which TSF has as an app property, not a TSF property.
TextService::Field TextService::field(ITfContext *context) {
  if (field_ != Field::Unknown) return field_;
  Field found = Field::Text;
  ITfReadOnlyProperty *prop = nullptr;
  if (FAILED(context->GetAppProperty(kPropInputScope, &prop)) || !prop) return field_ = found;
  const HRESULT read = editSession(
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
              for (UINT i = 0; i < count; ++i) {
                if (scopes[i] == IS_PASSWORD) found = Field::Password;
                else if (scopes[i] == IS_PRIVATE && found == Field::Text) found = Field::Private;
              }
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
  if (SUCCEEDED(read)) field_ = found;
  return found;
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

// The character the key types in the app, as TranslateMessage gives it (keypad digits and operators too),
// or 0.
wchar_t TextService::typedChar(WPARAM wParam, LPARAM lParam) {
  BYTE state[256];
  wchar_t ch[4];
  if (!GetKeyboardState(state)) return 0;
  const int n = ToUnicodeEx(static_cast<UINT>(wParam), (lParam >> 16) & 0xff, state, ch, 4, 0x4, GetKeyboardLayout(0));
  return n == 1 && ch[0] >= 0x20 && ch[0] != 0x7f ? ch[0] : 0;
}

bool TextService::send(const Request &request) {
  if (server.call(request, reply_)) {
    warned_ = false;
    return true;
  }
  if (GetLastError() == ERROR_TIMEOUT) return false;  // a server that hangs: the key goes to the app as typed
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
  // Until it answers, for at most 3 s; one that ends (it crashed, or another one runs) or hangs ends the wait.
  bool up = false;
  for (int i = 0; i < 60 && !up; ++i) {
    const bool ended = WaitForSingleObject(pi.hProcess, 50) == WAIT_OBJECT_0;
    up = server.call(request, reply_);
    if (ended || (!up && GetLastError() == ERROR_TIMEOUT)) break;
  }
  CloseHandle(pi.hProcess);
  if (up) warned_ = false;
  return up;
}

bool TextService::unavailable(ITfContext *context, const Key &k, wchar_t ch) {
  if (k.release || (k.mods & (mod::Ctrl | mod::Alt))) ch = 0;
  const bool typed = ch || (!k.release && k.sym < 0xff00 && !(k.mods & (mod::Ctrl | mod::Alt)));
  const std::string icon = notReadyIcon(lang_, Readiness::Unavailable);
  // What was being typed goes in once, as it showed: the keys that follow go to the app as typed, after it,
  // and no reply the server owed (its Reset drops that typing) can change it later.
  const bool composing = composition_ || !reply_.preedit.empty() || !reply_.page.empty() || !reply_.aux.empty();
  if (composing) {
    for (const Segment &seg : reply_.preedit.segments) reply_.commit += seg.text;
    // The key's character goes in after it, in the same edit: given to the app, it could land before the
    // commit when the app grants the edit's lock later.
    if (ch) reply_.commit += utf8(std::wstring(1, ch));
    reply_.preedit = {};
    reply_.page = {};
    reply_.aux.clear();
  }
  if (!composing && reply_.icon == icon && (!typed || warned_)) return false;
  reply_.lang = lang_;
  reply_.icon = icon;
  if (typed && !std::exchange(warned_, true)) {
    const LANGID ui = PRIMARYLANGID(GetUserDefaultUILanguage());
    reply_.notice = notReadyNotice(lang_, Readiness::Unavailable,
                                   ui == LANG_CHINESE ? Lang::Chinese : ui == LANG_JAPANESE ? Lang::Japanese : Lang::English);
  }
  apply(context);
  return composing && ch;
}

void TextService::watchReadiness() {
  if (poll_ || !notReady(reply_.icon)) return;
  if (watching && watching != this) watching->stopWatching();
  watching = this;
  poll_ = SetTimer(nullptr, 0, 1000, [](HWND, UINT, UINT_PTR, DWORD) {
    if (watching) watching->pollReadiness();
  });
}

// Asks only for the icon: the apps share the server's core, and another app's composition or language is
// not this one's to change. Never starts a server (an idle app would wait for it), a key does.
void TextService::pollReadiness() {
  Request q{Op::Ready};
  q.lang = lang_;
  Reply r;
  if (!server.call(q, r)) return;
  warned_ = false;
  reply_.icon = r.icon;
  if (button_) button_->update();
  if (!notReady(r.icon)) stopWatching();
}

void TextService::stopWatching() {
  if (poll_) KillTimer(nullptr, poll_);
  poll_ = 0;
  if (watching == this) watching = nullptr;
}

void TextService::apply(ITfContext *context) {
  if (context) editSession(context, clientId_, [this, context](TfEditCookie ec) { return update(ec, context); }, false);
  if (button_) button_->update();
  watchReadiness();
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
  if (!context) return true;
  const Field f = field(context);
  if (f == Field::Password) return true;
  followLayout();
  Request q{Op::Key};
  q.lang = lang_;
  q.learning = f != Field::Private;
  if (!key(wParam, lParam, release, q.key)) return true;
  if (!send(q)) {
    trace("key " + std::to_string(q.key.sym) + (release ? " up" : " down") + (test ? " test" : "") + ": send failed");  // TEMP #327
    *eaten = unavailable(context, q.key, typedChar(wParam, lParam));
    if (test) tested_ = {wParam, release, *eaten != FALSE, true};
    return true;
  }
  trace("key " + std::to_string(q.key.sym) + (release ? " up" : " down") + (test ? " test" : "") + ": taken " +
        std::to_string(reply_.taken) + " icon '" + reply_.icon + "' notice '" + reply_.notice + "'");  // TEMP #327
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

// --- The app ended the composition (a click elsewhere in the text, say): what was typed goes in where it
// was, as when focus moves away (#277). The app keeps the caret where it put it. ---

STDMETHODIMP TextService::OnCompositionTerminated(TfEditCookie ec, ITfComposition *composition) {
  if (composition == composition_) {
    std::wstring typed;
    if (send({Op::FocusOut})) typed = utf16(std::exchange(reply_.commit, {}));
    if (!leaving_ && !active()) leaving_ = true;
    if (leaving_) typed.clear();  // the text goes, kana and all, for the next keyboard (#301)
    ITfRange *range = nullptr;
    if ((leaving_ || !typed.empty()) && SUCCEEDED(composition_->GetRange(&range))) {
      range->SetText(ec, 0, typed.c_str(), static_cast<LONG>(typed.size()));
      range->Release();
    }
    composition_->Release();
    composition_ = nullptr;
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
