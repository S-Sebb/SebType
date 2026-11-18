// SebType on Windows: the text service (TSF) in each app. It takes the keys of SebType's two input
// methods, 中文 and 日本語 (one service, two language profiles; English is Windows' US layout), passes them
// to the SebType server, and draws what the server says: the text, the composition, the candidate
// window and the tray button with its menu. MIT, SebType.
#pragma once

#include "../pipe.h"

#include <sebtype/not_ready.h>

#include <msctf.h>
#include <ole2.h>

#include <atomic>
#include <memory>
#include <string>

namespace sebtype::win {

// {D4E5C593-4F73-475F-936C-0E29A6FE7A02}
inline constexpr GUID kClsid = {0xd4e5c593, 0x4f73, 0x475f, {0x93, 0x6c, 0x0e, 0x29, 0xa6, 0xfe, 0x7a, 0x02}};
// 中文 (zh-CN) and 日本語 (ja-JP), the two profiles Windows lists and Win+Space switches between.
inline constexpr GUID kProfileZh = {0x8aa7ddac, 0xa4b8, 0x4437, {0x9c, 0x0b, 0x86, 0x98, 0x87, 0x9e, 0xc9, 0x87}};
inline constexpr GUID kProfileJa = {0xb148fb02, 0xc235, 0x45d6, {0x99, 0x6c, 0x67, 0x2c, 0x78, 0x3e, 0xcd, 0x48}};
// The composition's display attributes: being typed, and the segment Mozc converts.
inline constexpr GUID kAttrInput = {0x4bcfd6dc, 0xe2ab, 0x4cf0, {0x92, 0xef, 0x1f, 0x7b, 0x18, 0xa2, 0xeb, 0x88}};
inline constexpr GUID kAttrTarget = {0x8d3f6ec2, 0x5a30, 0x4fae, {0xb7, 0xd1, 0xd0, 0x90, 0x83, 0x9d, 0x4d, 0x28}};
inline constexpr LANGID kLangZh = MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED);
inline constexpr LANGID kLangJa = MAKELANGID(LANG_JAPANESE, SUBLANG_JAPANESE_JAPAN);

inline constexpr wchar_t kWindowClass[] = L"SebType.Candidates";

extern HINSTANCE dllInstance;
extern std::atomic<long> dllRefs;

class CandidateWindow;
class LangBarButton;

class TextService final : public ITfTextInputProcessorEx,
                          public ITfThreadMgrEventSink,
                          public ITfKeyEventSink,
                          public ITfCompositionSink,
                          public ITfDisplayAttributeProvider,
                          public ITfInputProcessorProfileActivationSink {
 public:
  TextService();
  ~TextService();

  // IUnknown
  STDMETHODIMP QueryInterface(REFIID riid, void **out) override;
  STDMETHODIMP_(ULONG) AddRef() override;
  STDMETHODIMP_(ULONG) Release() override;

  // ITfTextInputProcessorEx
  STDMETHODIMP Activate(ITfThreadMgr *threadMgr, TfClientId clientId) override;
  STDMETHODIMP ActivateEx(ITfThreadMgr *threadMgr, TfClientId clientId, DWORD flags) override;
  STDMETHODIMP Deactivate() override;

  // ITfThreadMgrEventSink
  STDMETHODIMP OnInitDocumentMgr(ITfDocumentMgr *) override { return S_OK; }
  STDMETHODIMP OnUninitDocumentMgr(ITfDocumentMgr *) override { return S_OK; }
  STDMETHODIMP OnSetFocus(ITfDocumentMgr *focus, ITfDocumentMgr *previous) override;
  STDMETHODIMP OnPushContext(ITfContext *) override { return S_OK; }
  STDMETHODIMP OnPopContext(ITfContext *) override { return S_OK; }

  // ITfKeyEventSink
  STDMETHODIMP OnSetFocus(BOOL foreground) override;
  STDMETHODIMP OnTestKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) override;
  STDMETHODIMP OnKeyDown(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) override;
  STDMETHODIMP OnTestKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) override;
  STDMETHODIMP OnKeyUp(ITfContext *context, WPARAM wParam, LPARAM lParam, BOOL *eaten) override;
  STDMETHODIMP OnPreservedKey(ITfContext *, REFGUID, BOOL *eaten) override {
    *eaten = FALSE;
    return S_OK;
  }

  // ITfCompositionSink
  STDMETHODIMP OnCompositionTerminated(TfEditCookie ec, ITfComposition *composition) override;

  // ITfDisplayAttributeProvider
  STDMETHODIMP EnumDisplayAttributeInfo(IEnumTfDisplayAttributeInfo **out) override;
  STDMETHODIMP GetDisplayAttributeInfo(REFGUID guid, ITfDisplayAttributeInfo **out) override;

  // ITfInputProcessorProfileActivationSink
  STDMETHODIMP OnActivated(DWORD profileType, LANGID langid, REFCLSID clsid, REFGUID catid, REFGUID profile,
                           HKL hkl, DWORD flags) override;

  // The candidate window's clicks and wheel, and the tray menu's picks.
  void select(int indexOnPage);
  void page(bool next);
  void menu(int index);
  void toggleLatin();
  const Reply &reply() const { return reply_; }

  // For the edit sessions (edit.cpp).
  HRESULT update(TfEditCookie ec, ITfContext *context);
  HRESULT endComposition(TfEditCookie ec, ITfContext *context);
  // Puts text where a composition is (replacing its pinyin or kana), the caret after it, and ends it.
  static void endComposition(TfEditCookie ec, ITfContext *context, ITfComposition *composition,
                             const std::wstring &text);
  // The same for context_'s composition, in a session of its own.
  void typeIn(const std::wstring &typed);
  bool active();

 private:
  // A key as the server takes it, from Windows' key message; false for keys SebType never takes.
  bool key(WPARAM wParam, LPARAM lParam, bool release, Key &out);
  // Asks the server (starting it when none answers) and applies the reply in an edit session.
  bool send(const Request &request);
  void apply(ITfContext *context);
  bool keyEvent(ITfContext *context, WPARAM wParam, LPARAM lParam, bool release, bool test, BOOL *eaten);
  void setLanguage(REFGUID profile);
  void followLayout();
  // The focused field's input scope, asked once per focus: a password field, where keys go to the app as they
  // are (as Mozc did), or a private one, where nothing typed is learned (#270).
  enum class Field { Unknown, Text, Private, Password };
  Field field(ITfContext *context);
  void setOpen();
  void focus(ITfDocumentMgr *focus);
  // The server didn't take a key (#275): the key in grey with "!", and the popup at the first typed key.
  // True when it took the key itself: ch, the character it types, goes in after what was being typed.
  bool unavailable(ITfContext *context, const Key &key, wchar_t ch);
  static wchar_t typedChar(WPARAM wParam, LPARAM lParam);
  // While the language isn't ready, its state is asked again every second until the key is 中 or あ again.
  void watchReadiness();
  void pollReadiness();
  void stopWatching();

  std::atomic<long> refs_{1};
  ITfThreadMgr *threadMgr_ = nullptr;
  TfClientId clientId_ = TF_CLIENTID_NULL;
  DWORD threadMgrCookie_ = TF_INVALID_COOKIE, activationCookie_ = TF_INVALID_COOKIE;
  ITfComposition *composition_ = nullptr;
  ITfContext *context_ = nullptr;  // the focused one, for clicks and menu picks
  Field field_ = Field::Unknown;
  TfGuidAtom attrInput_ = TF_INVALID_GUIDATOM, attrTarget_ = TF_INVALID_GUIDATOM;
  Lang lang_ = Lang::Chinese;
  Reply reply_;
  bool leaving_ = false;  // another keyboard is being activated: what was typed is dropped (#301)
  RECT caret_{};
  // OnTestKeyDown already sent this key; OnKeyDown takes its answer instead of sending it again.
  struct Tested {
    WPARAM wParam = 0;
    bool release = false, eaten = false, pending = false;
  } tested_;
  std::unique_ptr<CandidateWindow> window_;
  LangBarButton *button_ = nullptr;
  DWORD serverStarted_ = 0;  // GetTickCount of the last start, so a missing server isn't started every key
  bool warned_ = false;      // the popup said the server doesn't answer, once until it does
  UINT_PTR poll_ = 0;        // watchReadiness's timer
};

}  // namespace sebtype::win
