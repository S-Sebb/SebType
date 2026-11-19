// SebType on Windows: what the server's reply does to the app's text, in an edit session: the committed
// text, the composition and the candidate window at the caret. Chinese keeps its pinyin in the window and an
// empty composition in the text (Weasel's inline_preedit: false); Japanese types inline, as Mozc did.
// MIT, SebType.
#include "candidate_window.h"
#include "edit_session.h"

namespace sebtype::win {
namespace {

// Where the caret is, for the window; Windows' caret when the app can't say. In the screen's own pixels, as
// the window places itself (candidate_window.cpp): a DPI-unaware app's are scaled.
RECT caretRect(TfEditCookie ec, ITfContext *context, ITfRange *range) {
  RECT rect{};
  HWND wnd = nullptr;
  ITfContextView *view = nullptr;
  BOOL clipped = FALSE;
  if (range && SUCCEEDED(context->GetActiveView(&view))) {
    if (FAILED(view->GetTextExt(ec, range, &rect, &clipped))) rect = {};
    if (FAILED(view->GetWnd(&wnd))) wnd = nullptr;
    view->Release();
  }
  if (rect.left == 0 && rect.top == 0 && rect.right == 0 && rect.bottom == 0) {
    GUITHREADINFO gui{sizeof(gui)};
    if (GetGUIThreadInfo(GetCurrentThreadId(), &gui) && gui.hwndCaret) {
      rect = gui.rcCaret;
      MapWindowPoints(gui.hwndCaret, nullptr, reinterpret_cast<POINT *>(&rect), 2);
      wnd = gui.hwndCaret;
    }
  }
  POINT corners[2] = {{rect.left, rect.top}, {rect.right, rect.bottom}};
  if (wnd && LogicalToPhysicalPointForPerMonitorDPI(wnd, &corners[0]) &&
      LogicalToPhysicalPointForPerMonitorDPI(wnd, &corners[1]))
    rect = {corners[0].x, corners[0].y, corners[1].x, corners[1].y};
  return rect;
}

void setSelection(TfEditCookie ec, ITfContext *context, ITfRange *range) {
  TF_SELECTION sel{};
  sel.range = range;
  sel.style.ase = TF_AE_NONE;
  sel.style.fInterimChar = FALSE;
  context->SetSelection(ec, 1, &sel);
}

// The UTF-16 length of the first bytes of a UTF-8 text.
LONG length16(const std::string &text, size_t bytes) {
  return static_cast<LONG>(utf16(text.substr(0, std::min(bytes, text.size()))).size());
}

// The UTF-16 length of the last chars characters of text, or -1 when it has fewer.
LONG suffix16(const std::wstring &text, int chars) {
  size_t at = text.size();
  for (; chars > 0 && at > 0; --chars)
    if (--at > 0 && IS_LOW_SURROGATE(text[at]) && IS_HIGH_SURROGATE(text[at - 1])) --at;
  return chars ? -1 : static_cast<LONG>(text.size() - at);
}

// The empty selection, or none (null).
ITfRange *caret(TfEditCookie ec, ITfContext *context) {
  TF_SELECTION sel{};
  ULONG n = 0;
  BOOL empty = FALSE;
  if (FAILED(context->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &n)) || !n) return nullptr;
  if (SUCCEEDED(sel.range->IsEmpty(ec, &empty)) && empty) return sel.range;
  sel.range->Release();
  return nullptr;
}

// Up to units UTF-16 units of the app's text before range, read whole, or false.
bool readBefore(TfEditCookie ec, ITfRange *range, LONG units, std::wstring &text) {
  LONG moved = 0;
  ULONG got = 0;
  range->Collapse(ec, TF_ANCHOR_START);
  if (FAILED(range->ShiftStart(ec, -units, &moved, nullptr))) return false;
  text.assign(static_cast<size_t>(-moved), L'\0');
  if (FAILED(range->GetText(ec, 0, text.data(), static_cast<ULONG>(text.size()), &got)) || got != text.size())
    return false;
  return true;
}

// Deletes the characters just before the composition, or the caret when there is none: 日本語's undo of its
// last commit. False, deleting nothing, when the app's text there doesn't read back whole.
bool deleteBefore(TfEditCookie ec, ITfContext *context, ITfComposition *composition, int chars) {
  ITfRange *range = nullptr;
  if (composition) composition->GetRange(&range);
  else range = caret(ec, context);
  if (!range) return false;
  std::wstring text;
  LONG moved = 0;
  const LONG n = readBefore(ec, range, 2 * chars, text) ? suffix16(text, chars) : -1;
  const bool done = n >= 0 && SUCCEEDED(range->ShiftStart(ec, static_cast<LONG>(text.size()) - n, &moved, nullptr)) &&
                    moved == static_cast<LONG>(text.size()) - n && SUCCEEDED(range->SetText(ec, 0, L"", 0));
  range->Release();
  return done;
}

}  // namespace

std::string TextService::textBefore(ITfContext *context) {
  std::wstring text;
  if (!committed16_) return {};
  editSession(
      context, clientId_,
      [&](TfEditCookie ec) {
        if (ITfRange *range = caret(ec, context)) {
          if (!readBefore(ec, range, committed16_, text)) text.clear();
          range->Release();
        }
        return S_OK;
      },
      true, TF_ES_READ);
  return utf8(text);
}

void TextService::endComposition(TfEditCookie ec, ITfContext *context, ITfComposition *composition,
                                 const std::wstring &text) {
  ITfRange *range = nullptr;
  if (SUCCEEDED(composition->GetRange(&range))) {
    range->SetText(ec, 0, text.c_str(), static_cast<LONG>(text.size()));
    range->Collapse(ec, TF_ANCHOR_END);
    setSelection(ec, context, range);
    range->Release();
  }
  composition->EndComposition(ec);
  composition->Release();
}

// The session may run once focus or the language moved on: it keeps its own context and composition.
void TextService::typeIn(const std::wstring &typed) {
  if (!composition_) return;
  ITfContext *context = context_;
  ITfComposition *composition = std::exchange(composition_, nullptr);
  context->AddRef();
  const auto end = [context, composition, typed](TfEditCookie ec) {
    endComposition(ec, context, composition, typed);
    context->Release();
    return S_OK;
  };
  if (FAILED(editSession(context, clientId_, end, false))) {
    composition->Release();
    context->Release();
  }
}

// Leaves no pinyin or kana behind.
HRESULT TextService::endComposition(TfEditCookie ec, ITfContext *context) {
  if (composition_) endComposition(ec, context, std::exchange(composition_, nullptr), L"");
  return S_OK;
}

HRESULT TextService::update(TfEditCookie ec, ITfContext *context) {
  leaving_ = false;  // SebType is typing: a notice of its profile going was for its other language
  const std::wstring commit = utf16(reply_.commit);
  reply_.commit.clear();  // applied once
  const bool japanese = reply_.lang == Lang::Japanese;

  // Where the commit can't be deleted the undo stops: its conversion would type it again after the commit.
  if (reply_.deleteBefore > 0 && !deleteBefore(ec, context, composition_, std::exchange(reply_.deleteBefore, 0))) {
    reply_.preedit = {};
    reply_.page = {};
    reply_.aux.clear();
    dropTyping();
  }
  const bool composing = !reply_.preedit.empty() || !reply_.page.empty() || !reply_.aux.empty();

  // The committed text goes where the composition is, or at the caret.
  if (!commit.empty()) {
    committed16_ = static_cast<LONG>(commit.size());
    if (composition_) {
      endComposition(ec, context, std::exchange(composition_, nullptr), commit);
    } else {
      ITfInsertAtSelection *insert = nullptr;
      ITfRange *range = nullptr;
      if (SUCCEEDED(context->QueryInterface(IID_ITfInsertAtSelection, reinterpret_cast<void **>(&insert)))) {
        if (SUCCEEDED(insert->InsertTextAtSelection(ec, 0, commit.c_str(), static_cast<LONG>(commit.size()),
                                                    &range))) {
          range->Collapse(ec, TF_ANCHOR_END);
          setSelection(ec, context, range);
          range->Release();
        }
        insert->Release();
      }
    }
  }

  if (!composing) {
    endComposition(ec, context);
    // A notice stays its moment: the release of the key that showed it comes with nothing to show (#275).
    if (window_ && !window_->noticing()) window_->hide();
  } else {
    if (!composition_) {
      ITfInsertAtSelection *insert = nullptr;
      ITfContextComposition *compose = nullptr;
      ITfRange *range = nullptr;
      if (SUCCEEDED(context->QueryInterface(IID_ITfInsertAtSelection, reinterpret_cast<void **>(&insert))) &&
          SUCCEEDED(insert->InsertTextAtSelection(ec, TF_IAS_QUERYONLY, nullptr, 0, &range)) &&
          SUCCEEDED(context->QueryInterface(IID_ITfContextComposition, reinterpret_cast<void **>(&compose))))
        compose->StartComposition(ec, range, static_cast<ITfCompositionSink *>(this), &composition_);
      if (compose) compose->Release();
      if (range) range->Release();
      if (insert) insert->Release();
    }
    ITfRange *range = nullptr;
    if (composition_ && SUCCEEDED(composition_->GetRange(&range))) {
      if (japanese) {
        std::string text;
        for (const Segment &seg : reply_.preedit.segments) text += seg.text;
        const std::wstring text16 = utf16(text);
        range->SetText(ec, TF_ST_CORRECTION, text16.c_str(), static_cast<LONG>(text16.size()));
        // Each segment's underline: what is typed, and the segment being converted.
        ITfProperty *attrs = nullptr;
        if (SUCCEEDED(context->GetProperty(GUID_PROP_ATTRIBUTE, &attrs))) {
          attrs->Clear(ec, range);
          size_t at = 0;
          for (const Segment &seg : reply_.preedit.segments) {
            ITfRange *part = nullptr;
            LONG moved = 0;
            if (SUCCEEDED(range->Clone(&part))) {
              part->Collapse(ec, TF_ANCHOR_START);
              part->ShiftEnd(ec, length16(text, at + seg.text.size()), &moved, nullptr);
              part->ShiftStart(ec, length16(text, at), &moved, nullptr);
              VARIANT v;
              v.vt = VT_I4;
              v.lVal = static_cast<LONG>(seg.highlight ? attrTarget_ : attrInput_);
              attrs->SetValue(ec, part, &v);
              part->Release();
            }
            at += seg.text.size();
          }
          attrs->Release();
        }
        // The caret where Mozc says, else at the end.
        ITfRange *caret = nullptr;
        if (SUCCEEDED(range->Clone(&caret))) {
          LONG moved = 0;
          caret->Collapse(ec, TF_ANCHOR_START);
          const size_t at = reply_.preedit.cursor < 0 ? text.size() : static_cast<size_t>(reply_.preedit.cursor);
          caret->ShiftStart(ec, length16(text, at), &moved, nullptr);
          caret->Collapse(ec, TF_ANCHOR_START);
          setSelection(ec, context, caret);
          caret->Release();
        }
      }
      // The window under the composition's start, where the next character goes.
      ITfRange *start = nullptr;
      if (SUCCEEDED(range->Clone(&start))) {
        start->Collapse(ec, TF_ANCHOR_START);
        caret_ = caretRect(ec, context, start);
        start->Release();
      }
      range->Release();
    }
    if (window_) window_->show(reply_, !japanese, caret_);
  }

  // 中文's English mode switch says so for a moment, as Weasel's tip did.
  if (!reply_.notice.empty() && window_ && !composing) {
    TF_SELECTION sel{};
    ULONG n = 0;
    if (SUCCEEDED(context->GetSelection(ec, TF_DEFAULT_SELECTION, 1, &sel, &n)) && n) {
      caret_ = caretRect(ec, context, sel.range);
      sel.range->Release();
    }
    window_->notice(reply_.notice, caret_);
  }
  reply_.notice.clear();
  return S_OK;
}

}  // namespace sebtype::win
