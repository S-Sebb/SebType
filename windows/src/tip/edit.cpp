// SebType on Windows: what the server's reply does to the app's text, in an edit session: the committed
// text, the composition and the candidate window at the caret. Chinese keeps its pinyin in the window and an
// empty composition in the text (Weasel's inline_preedit: false); Japanese types inline, as Mozc did.
// MIT, SebType.
#include "candidate_window.h"
#include "edit_session.h"

namespace sebtype::win {
namespace {

// Where the caret is, for the window; Windows' caret when the app can't say.
RECT caretRect(TfEditCookie ec, ITfContext *context, ITfRange *range) {
  RECT rect{};
  ITfContextView *view = nullptr;
  BOOL clipped = FALSE;
  if (range && SUCCEEDED(context->GetActiveView(&view))) {
    if (FAILED(view->GetTextExt(ec, range, &rect, &clipped))) rect = {};
    view->Release();
  }
  if (rect.left == 0 && rect.top == 0 && rect.right == 0 && rect.bottom == 0) {
    GUITHREADINFO gui{sizeof(gui)};
    if (GetGUIThreadInfo(GetCurrentThreadId(), &gui) && gui.hwndCaret) {
      rect = gui.rcCaret;
      MapWindowPoints(gui.hwndCaret, nullptr, reinterpret_cast<POINT *>(&rect), 2);
    }
  }
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

}  // namespace

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
  const bool composing = !reply_.preedit.empty() || !reply_.page.empty() || !reply_.aux.empty();

  // The committed text goes where the composition is, or at the caret.
  if (!commit.empty()) {
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
    if (window_) window_->hide();
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
