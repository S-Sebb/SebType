// SPDX-License-Identifier: BSD-3-Clause
// SebType core: 日本語 through Mozc, the same protocol on every platform; mozc_transport.h says how it is
// reached. The key translation, the candidate window and the protocol use follow fcitx5-mozc (Copyright
// 2010-2018 Google Inc. and 2017 Weng Xuetian; fcitx/mozc's src/unix/fcitx5), and the touch keyboard's
// requests and settings follow Mozc's Android client (Copyright 2010-2018 Google Inc.), so this file keeps
// their licence: see core/README.md.
#include <sebtype/hosts.h>

#ifndef _WIN32
#include <unistd.h>
#endif

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <utility>

#include "mozc_transport.h"
#include "protocol/commands.pb.h"
#include "protocol/config.pb.h"

#ifdef _WIN32  // after the protocol's headers: its macros (DELETE, GetMessage) would clash with them
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace sebtype {

namespace {

using mozc::commands::Command;
using mozc::commands::CompositionMode;
using mozc::commands::Input;
using mozc::commands::KeyEvent;
using mozc::commands::Output;
using mozc::commands::SessionCommand;

// X11 keysyms Mozc takes as special keys (fcitx5-mozc's kSpecialKeyMap, the keys a US layout has).
const std::map<uint32_t, KeyEvent::SpecialKey> &specialKeys() {
  static const std::map<uint32_t, KeyEvent::SpecialKey> map = [] {
    std::map<uint32_t, KeyEvent::SpecialKey> m{
        {0x20, KeyEvent::SPACE},        {0xff0d, KeyEvent::ENTER},      {0xff51, KeyEvent::LEFT},
        {0xff53, KeyEvent::RIGHT},      {0xff52, KeyEvent::UP},         {0xff54, KeyEvent::DOWN},
        {0xff1b, KeyEvent::ESCAPE},     {0xffff, KeyEvent::DEL},        {0xff08, KeyEvent::BACKSPACE},
        {0xff63, KeyEvent::INSERT},     {0xff23, KeyEvent::HENKAN},     {0xff22, KeyEvent::MUHENKAN},
        {0xff25, KeyEvent::KANA},       {0xff27, KeyEvent::KANA},       {0xff26, KeyEvent::KATAKANA},
        {0xff28, KeyEvent::HANKAKU},    {0xff29, KeyEvent::HANKAKU},    {0xff2a, KeyEvent::HANKAKU},
        {0xff30, KeyEvent::EISU},       {0xff50, KeyEvent::HOME},       {0xff57, KeyEvent::END},
        {0xff09, KeyEvent::TAB},        {0xfe20, KeyEvent::TAB},        {0xff55, KeyEvent::PAGE_UP},
        {0xff56, KeyEvent::PAGE_DOWN},  {0xffe5, KeyEvent::CAPS_LOCK},  {0xff31, KeyEvent::ON},
        {0xff34, KeyEvent::OFF},        {0xffbd, KeyEvent::EQUALS},     {0xffaa, KeyEvent::MULTIPLY},
        {0xffab, KeyEvent::ADD},        {0xffac, KeyEvent::SEPARATOR},  {0xffad, KeyEvent::SUBTRACT},
        {0xffae, KeyEvent::DECIMAL},    {0xffaf, KeyEvent::DIVIDE},     {0xff80, KeyEvent::SPACE},
        {0xff89, KeyEvent::TAB},        {0xff8d, KeyEvent::ENTER},      {0xff95, KeyEvent::HOME},
        {0xff96, KeyEvent::LEFT},       {0xff97, KeyEvent::UP},         {0xff98, KeyEvent::RIGHT},
        {0xff99, KeyEvent::DOWN},       {0xff9a, KeyEvent::PAGE_UP},    {0xff9b, KeyEvent::PAGE_DOWN},
        {0xff9c, KeyEvent::END},        {0xff9e, KeyEvent::INSERT},     {0xff9f, KeyEvent::DEL},
    };
    for (int i = 0; i < 24; ++i) m[0xffbe + i] = static_cast<KeyEvent::SpecialKey>(KeyEvent::F1 + i);
    for (int i = 0; i < 10; ++i) m[0xffb0 + i] = static_cast<KeyEvent::SpecialKey>(KeyEvent::NUMPAD0 + i);
    return m;
  }();
  return map;
}

bool isAscii(uint32_t sym) { return sym > 0x20 && sym <= 0x7e; }  // Space is a special key in Mozc

bool isImeKey(const KeyEvent &k) {
  switch (k.special_key()) {
    case KeyEvent::HANKAKU: case KeyEvent::KANA: case KeyEvent::KATAKANA: case KeyEvent::EISU:
    case KeyEvent::ON: case KeyEvent::OFF: case KeyEvent::HENKAN: case KeyEvent::MUHENKAN:
      return true;
    default:
      return false;
  }
}

// fcitx5-mozc's KeyTranslator::Translate for romaji input: false for keys Mozc doesn't know.
bool translate(const Key &k, KeyEvent &out) {
  if (k.mods & mod::Super) return false;
  if (isAscii(k.sym)) {
    if (k.mods & mod::Lock) out.add_modifier_keys(KeyEvent::CAPS);
    out.set_key_code(k.sym);
  } else if (auto it = specialKeys().find(k.sym); it != specialKeys().end()) {
    out.set_special_key(it->second);
  } else {
    return false;
  }
  const bool printable = isAscii(k.sym) && !(k.mods & (mod::Ctrl | mod::Alt));
  if ((k.mods & mod::Shift) && !printable) out.add_modifier_keys(KeyEvent::SHIFT);
  if (k.mods & mod::Ctrl) out.add_modifier_keys(KeyEvent::CTRL);
  if (k.mods & mod::Alt) out.add_modifier_keys(KeyEvent::ALT);
  return true;
}

// A touch keyboard's key as Mozc's Android client sent it: a character's code point, or one of the keys it
// has, Enter and the arrows being the virtual ones.
bool translateTouch(const Key &k, KeyEvent &out) {
  switch (k.sym) {
    case 0x20: out.set_special_key(KeyEvent::SPACE); return true;
    case 0xff08: out.set_special_key(KeyEvent::BACKSPACE); return true;
    case 0xff0d: out.set_special_key(KeyEvent::VIRTUAL_ENTER); return true;
    case 0xff51: out.set_special_key(KeyEvent::VIRTUAL_LEFT); return true;
    case 0xff53: out.set_special_key(KeyEvent::VIRTUAL_RIGHT); return true;
  }
  // Characters only (charSym): Latin-1 printables and Unicode keysyms.
  const bool latin1 = (k.sym > 0x20 && k.sym < 0x7f) || (k.sym >= 0xa0 && k.sym < 0x100);
  if (!latin1 && k.sym < 0x1000000) return false;
  out.set_key_code(latin1 ? k.sym : k.sym - 0x1000000);
  return true;
}

// The touch keyboards Mozc's Android client asked for (its Keyboard.KeyboardSpecification): QWERTY in
// romaji, QWERTY letters, and the symbols and numbers.
struct TouchKeyboard {
  const char *name;
  CompositionMode mode;
  mozc::commands::Request::SpecialRomanjiTable table;
  mozc::commands::Request::SpaceOnAlphanumeric space;
  mozc::commands::Request::CrossingEdgeBehavior edge;
};
const TouchKeyboard &touchKeyboard(Keys keys) {
  using R = mozc::commands::Request;
  static const TouchKeyboard kana{"QWERTY_KANA-0.4.0", mozc::commands::HIRAGANA, R::QWERTY_MOBILE_TO_HIRAGANA,
                                  R::SPACE_OR_CONVERT_KEEPING_COMPOSITION, R::DO_NOTHING},
      letters{"QWERTY_ALPHABET-0.5.0", mozc::commands::HALF_ASCII, R::QWERTY_MOBILE_TO_HALFWIDTHASCII, R::COMMIT,
              R::COMMIT_WITHOUT_CONSUMING},
      symbols{"TWELVE_KEY_SYMBOL_NUMBER-0.1.0", mozc::commands::HALF_ASCII, R::QWERTY_MOBILE_TO_HALFWIDTHASCII,
              R::COMMIT, R::DO_NOTHING};
  return keys == Keys::Letters ? letters : keys == Keys::Symbols ? symbols : kana;
}

class Mozc final : public Engine {
 public:
  explicit Mozc(const MozcPaths &paths)
      : mozc_(makeMozcTransport(paths)), rimeUserDir_(paths.rimeUserDir), touch_(paths.touch) {}

  ~Mozc() override {
    if (!session_) return;
    Input in;
    in.set_type(Input::DELETE_SESSION);
    in.set_id(session_);
    Output out;
    mozc_->call(in, out);
  }

  bool busy() override { return mozc_->loading(); }
  bool available() override { return mozc_->open(); }

  bool key(const Key &k) override {
    if (k.release) return false;
    Input in;
    in.set_type(Input::SEND_KEY);
    if (!(touch_ ? translateTouch(k, *in.mutable_key()) : translate(k, *in.mutable_key()))) return false;
    // In English letters only the keys that may turn Japanese on (Hankaku/Zenkaku, Kana…) go to the server.
    if (direct_ && !isImeKey(in.key())) return false;
    if (!touch_) in.mutable_key()->set_mode(kana_);
    // The PCs: Mozc's undo may delete its last commit only where it is, just before the caret (#376).
    const std::string before = std::exchange(before_, {});
    undoable_ = !lastCommit_.empty() && before.ends_with(lastCommit_);
    return send(in);
  }
  // The PCs give the text before the caret for Ctrl+Backspace alone, and none where the app can't delete it.
  void setContext(const std::string &before, const std::string &, bool selection) override {
    if (!touch_) before_ = selection ? std::string{} : before;
  }

  std::string takeCommit() override { return std::exchange(commit_, {}); }
  Edit takeEdit() override { return std::exchange(edit_, {}); }
  Preedit preedit() override { return preedit_; }
  std::string aux() override { return aux_; }
  bool composing() override { return !preedit_.empty(); }

  void flush() override { command(SessionCommand::SUBMIT); }
  void clear() override {
    // The phone also forgets the text before the cursor that Mozc predicts from (its client's resetContext).
    if (touch_) command(SessionCommand::RESET_CONTEXT);
    else if (!preedit_.empty() || !page_.empty()) command(SessionCommand::REVERT);
    lastCommit_.clear();  // focus moved or the app reset: Mozc's undo is not this field's
  }

  Page page() override { return page_; }
  void select(int indexOnPage) override {
    if (indexOnPage < 0 || indexOnPage >= static_cast<int>(ids_.size())) return;
    SessionCommand c;
    c.set_type(SessionCommand::SELECT_CANDIDATE);
    c.set_id(ids_[indexOnPage]);
    command(c);
  }
  void changePage(bool next) override {
    command(next ? SessionCommand::CONVERT_NEXT_PAGE : SessionCommand::CONVERT_PREV_PAGE);
  }

  // The phone's list: Mozc's all candidate words, a tap submitting one.
  std::vector<Candidate> candidates(int max) override {
    return {list_.begin(), list_.begin() + std::min<size_t>(list_.size(), std::max(max, 0))};
  }
  int highlighted() override { return focused_; }
  void selectAt(int index) override {
    if (index < 0 || index >= static_cast<int>(listIds_.size())) return;
    SessionCommand c;
    c.set_type(SessionCommand::SUBMIT_CANDIDATE);
    c.set_id(listIds_[index]);
    command(c);
  }

  void setField(Field field) override {
    using mozc::commands::Context;
    field_ = field == Field::Password ? Context::PASSWORD
             : field == Field::Phone  ? Context::TEL
             : field == Field::Number ? Context::NUMBER
                                      : Context::NORMAL;
    if (!touch_ || !session_) return;
    Input in;
    in.set_type(Input::SEND_COMMAND);
    in.mutable_command()->set_type(SessionCommand::SWITCH_INPUT_FIELD_TYPE);
    in.mutable_context()->set_input_field_type(field_);
    send(in);
  }

  void setKeys(Keys keys, bool landscape) override {
    keys_ = keys;
    landscape_ = landscape;
    if (session_) {
      setTouchRequest();
      switchMode();
    }
  }

  void moveCursor(int chars) override {
    SessionCommand c;
    c.set_type(SessionCommand::MOVE_CURSOR);
    c.set_cursor_position(chars);
    command(c);
  }
  bool undo() override { return command(SessionCommand::UNDO_OR_REWIND); }

  bool latin() override {
    ensureSession();
    return direct_;
  }
  void setLatin(bool on) override {
    SessionCommand c;
    c.set_type(on ? SessionCommand::TURN_OFF_IME : SessionCommand::TURN_ON_IME);
    c.set_composition_mode(kana_);
    command(c);
  }

  bool alternate() override {
    if (touch_) return katakana_;
    ensureSession();
    return kana_ == mozc::commands::FULL_KATAKANA || kana_ == mozc::commands::HALF_KATAKANA;
  }
  // あ ⇄ ア, from English letters too (the menu switch). On the phone, the bar's chip: ア types katakana on
  // the romaji keys (#38).
  void setAlternate(bool on) override {
    if (touch_) {
      katakana_ = on;
      if (session_) switchMode();
      return;
    }
    SessionCommand c;
    c.set_type(direct_ ? SessionCommand::TURN_ON_IME : SessionCommand::SWITCH_COMPOSITION_MODE);
    c.set_composition_mode(on ? mozc::commands::FULL_KATAKANA : mozc::commands::HIRAGANA);
    command(c);
  }

  // The phone's settings are SebType's: Mozc's own config tool is a PC thing.
  void applySettings(const Settings &s, bool learning) override {
    learning_ = learning;
    if (s.halfWidthSpace) halfWidthSpace_ = *s.halfWidthSpace;
    if (touch_) {
      if (session_) setConfig();
    } else {
      mozc_->setLearning(learning);
    }
  }

  void reload() override {
    clear();
    mozc_->reload();
    session_ = 0;  // the new instance has none
  }

  void forget() override {
    if (!touch_) {  // the PCs: Mozc deletes its history files while closed (#375)
      clear();
      mozc_->forget();
      session_ = 0;  // the new instance has none
      return;
    }
    for (auto type : {Input::CLEAR_USER_HISTORY, Input::CLEAR_USER_PREDICTION, Input::SYNC_DATA}) {
      Input in;
      in.set_type(type);
      Output out;
      mozc_->call(in, out);
    }
    mozc_->forgetRecord();
  }
  std::string forgetError() const override { return mozc_->forgetError(); }

  // The PCs: the candidates per page 中文 has, for Mozc's own pages (its default is 9). The phone: the user
  // dictionaries it wrote (Mozc reads them again).
  void deploy() override {
    if (touch_) {
      Input in;
      in.set_type(Input::RELOAD);
      Output out;
      mozc_->call(in, out);
    } else if (session_) {
      setRequest();
    }
  }

  void save() override {
    Input in;
    in.set_type(Input::SYNC_DATA);
    Output out;
    mozc_->call(in, out);
  }

 private:
  int rimePageSize() const {
    std::ifstream f(std::filesystem::u8path(rimeUserDir_ + "/default.custom.yaml"));
    for (std::string line; std::getline(f, line);) {
      const auto at = line.find("menu/page_size:");
      if (at != std::string::npos && line.find_first_not_of(' ') == at) {
        const int n = std::atoi(line.c_str() + at + 15);
        if (n > 0 && n <= 10) return n;
      }
    }
    return 6;
  }
  // For the whole server, and sessions made after it.
  void setRequest() {
    Input in;
    in.set_type(Input::SET_REQUEST);
    in.mutable_request()->set_candidate_page_size(rimePageSize());
    Output out;
    mozc_->call(in, out);
  }

  // The touch keyboard's request, as Mozc's Android client made it for a software keyboard.
  void setTouchRequest() {
    const TouchKeyboard &kb = touchKeyboard(keys_);
    Input in;
    in.set_type(Input::SET_REQUEST);
    in.set_id(session_);
    auto &r = *in.mutable_request();
    r.set_mixed_conversion(true);
    r.set_zero_query_suggestion(true);
    r.set_update_input_mode_from_surrounding_text(false);
    r.set_auto_partial_suggestion(true);
    r.set_keyboard_name(std::string(kb.name) + (landscape_ ? "-LANDSCAPE" : "-PORTRAIT"));
    r.set_special_romanji_table(kb.table);
    r.set_space_on_alphanumeric(kb.space);
    r.set_kana_modifier_insensitive_conversion(false);
    r.set_crossing_edge_behavior(kb.edge);
    Output out;
    mozc_->call(in, out);
  }

  void setConfig() {
    using C = mozc::config::Config;
    Input in;
    in.set_type(Input::SET_CONFIG);
    C &c = *in.mutable_config();
    c.set_session_keymap(C::MOBILE);
    c.set_selection_shortcut(C::NO_SHORTCUT);
    c.set_use_emoji_conversion(true);
    c.set_space_character_form(halfWidthSpace_ ? C::FUNDAMENTAL_HALF_WIDTH : C::FUNDAMENTAL_INPUT_MODE);
    c.set_use_kana_modifier_insensitive_conversion(true);
    c.set_use_typing_correction(true);
    c.set_yen_sign_character(C::YEN_SIGN);
    // While incognito Mozc still suggests from its history but adds nothing to it (#31, #158).
    c.set_history_learning_level(learning_ ? C::DEFAULT_HISTORY : C::READ_ONLY);
    c.mutable_general_config()->set_upload_usage_stats(false);
    Output out;
    mozc_->call(in, out);
  }

  // The keys' mode, or katakana on the romaji keys while the chip says ア.
  void switchMode() {
    const CompositionMode mode = touchKeyboard(keys_).mode;
    SessionCommand c;
    c.set_type(SessionCommand::SWITCH_COMPOSITION_MODE);
    c.set_composition_mode(katakana_ && mode == mozc::commands::HIRAGANA ? mozc::commands::FULL_KATAKANA : mode);
    command(c);
  }

  bool ensureSession() {
    if (session_) return true;
    if (!touch_) setRequest();
    Input in;
    in.set_type(Input::CREATE_SESSION);
    in.mutable_capability()->set_text_deletion(mozc::commands::Capability::DELETE_PRECEDING_TEXT);
    if (!touch_) in.mutable_application_info()->set_process_id(
#ifdef _WIN32
        GetCurrentProcessId()
#else
        getpid()
#endif
    );
    Output out;
    if (!mozc_->call(in, out) || !out.has_id()) return false;
    session_ = out.id();
    if (touch_) {
      setTouchRequest();
      setConfig();
      Input field;
      field.set_type(Input::SEND_COMMAND);
      field.set_id(session_);
      field.mutable_command()->set_type(SessionCommand::SWITCH_INPUT_FIELD_TYPE);
      field.mutable_context()->set_input_field_type(field_);
      Output ignored;
      mozc_->call(field, ignored);
      switchMode();
      return true;
    }
    SessionCommand on;  // Japanese starts in あ
    on.set_type(SessionCommand::TURN_ON_IME);
    on.set_composition_mode(mozc::commands::HIRAGANA);
    return command(on);
  }

  bool command(SessionCommand::CommandType type) {
    SessionCommand c;
    c.set_type(type);
    return command(c);
  }
  bool command(const SessionCommand &c) {
    Input in;
    in.set_type(Input::SEND_COMMAND);
    *in.mutable_command() = c;
    return send(in);
  }

  // Sends with this session, starting one (and the server) when there is none or the server restarted.
  bool send(Input &in) {
    for (int attempt = 0; attempt < 2; ++attempt) {
      if (!ensureSession()) return false;
      in.set_id(session_);
      Output out;
      if (mozc_->call(in, out) && out.error_code() == Output::SESSION_SUCCESS) return parse(out);
      session_ = 0;
    }
    return false;
  }

  // fcitx5-mozc's MozcResponseParser, with the text to delete; on the phone also what Mozc's Android client
  // read: the whole list and where the cursor goes after a commit.
  bool parse(const Output &out) {
    // A status may carry only undo_available (Session::MaybeSetUndoStatus, after a commit): its unset
    // activated would read as English letters, as on a switch away from 日本語 after typing (#190).
    if (out.has_status() && out.status().has_activated()) {
      direct_ = !out.status().activated();
      if (out.status().mode() != mozc::commands::DIRECT) kana_ = out.status().mode();
    } else if (out.has_mode()) {
      direct_ = out.mode() == mozc::commands::DIRECT;
      if (!direct_) kana_ = out.mode();
    }
    if (touch_) {
      // A key Mozc passes on may still commit (crossing the edge of the letters keyboard).
      if (out.has_result()) takeResult(out.result());
      list_.clear();
      listIds_.clear();
      focused_ = -1;
    }
    if (!out.consumed()) return false;
    if (touch_) {
      if (out.has_deletion_range() && out.deletion_range().offset() <= 0) {
        const int before = -out.deletion_range().offset();
        edit_.deleteBefore = before;
        edit_.deleteAfter = std::max(0, out.deletion_range().length() - before);
      }
      for (const auto &c : out.all_candidate_words().candidates()) {
        list_.push_back({c.value(), c.annotation().has_description() ? c.annotation().description() : ""});
        listIds_.push_back(c.id());
      }
      if (out.has_candidate_window() && out.candidate_window().has_focused_index())
        focused_ = static_cast<int>(out.candidate_window().focused_index());
    } else {
      if (out.has_result()) commit_ += out.result().value(), lastCommit_ = out.result().value();
      // Mozc's undo of its last commit (Ctrl+Backspace): the PCs leave the cursor after a commit, so all of it
      // is before the cursor.
      if (out.has_deletion_range()) edit_.deleteBefore = out.deletion_range().length();
    }
    preedit_ = {};
    if (out.has_preedit()) {
      std::string text;
      for (const auto &s : out.preedit().segment()) {
        text += s.value();
        preedit_.segments.push_back({s.value(), s.annotation() == mozc::commands::Preedit::Segment::UNDERLINE,
                                     s.annotation() == mozc::commands::Preedit::Segment::HIGHLIGHT});
      }
      // The phone draws its own cursor in the field's text; fcitx5-mozc puts it at the highlighted segment.
      const uint32_t pos = !touch_ && out.preedit().has_highlighted_position() ? out.preedit().highlighted_position()
                                                                               : out.preedit().cursor();
      preedit_.cursor = byteOffset(text, pos);
    }
    page_ = {};
    ids_.clear();
    aux_.clear();
    if (out.has_candidate_window()) parseCandidates(out.candidate_window());
    // Ctrl+Backspace only asks for the undo (Session::RequestUndo): it comes with this command, as
    // fcitx5-mozc sends it, where the commit is still just before the caret (key()). Only the last one.
    if (!touch_ && out.has_callback() && out.callback().session_command().type() == SessionCommand::UNDO &&
        std::exchange(undoable_, false)) {
      lastCommit_.clear();
      command(out.callback().session_command());
    }
    return true;
  }

  void takeResult(const mozc::commands::Result &r) {
    commit_ += r.value();
    // The cursor before the text (a pair of brackets): only "at its start" is kept, as the phone did.
    const int chars = static_cast<int>(charCount(r.value()));
    if (r.cursor_offset() != 0 && r.cursor_offset() == -chars) edit_.cursor = -chars;
  }

  void parseCandidates(const mozc::commands::CandidateWindow &w) {
    const bool indexVisible = w.has_footer() && w.footer().index_visible();
    if (w.has_footer()) {
      aux_ = w.footer().has_label() ? w.footer().label() : w.footer().sub_label();
      if (indexVisible) {
        aux_ += (aux_.empty() ? "" : " ") + std::to_string(w.focused_index() + 1) + "/" + std::to_string(w.size());
      }
    }
    std::map<int32_t, std::pair<std::string, std::string>> usages;
    for (const auto &u : w.usages().information()) {
      if (u.has_id() && u.has_description()) usages[u.id()] = {u.title(), u.description()};
    }
    const int n = w.candidate_size();
    if (n > 0) {
      page_.hasPrev = w.candidate(0).index() > 0;
      page_.hasNext = w.candidate(n - 1).index() + 1 < w.size();
    }
    bool labels = false;
    for (int i = 0; i < n; ++i) {
      const auto &c = w.candidate(i);
      const auto &a = c.annotation();
      Candidate item{a.prefix() + c.value() + a.suffix(), a.has_description() ? "[" + a.description() + "]" : ""};
      const bool focused = w.has_focused_index() && c.index() == w.focused_index();
      if (focused) page_.cursor = i;
      // Usage notes of the focused candidate (fcitx5-mozc's default, ExpandMode OnFocus).
      if (auto u = usages.find(c.information_id()); focused && c.has_information_id() && u != usages.end()) {
        if (u->second.first != c.value()) item.text += "\n" + u->second.first;
        item.text += "\n" + u->second.second;
      }
      std::string label = a.has_shortcut() ? a.shortcut() + ". " : indexVisible ? std::to_string(i + 1) + ". " : "";
      labels |= !label.empty();
      page_.labels.push_back(std::move(label));
      page_.items.push_back(std::move(item));
      ids_.push_back(c.id());
    }
    if (!labels) page_.labels.clear();
  }

  static int byteOffset(const std::string &s, uint32_t chars) {
    size_t i = 0;
    for (uint32_t n = 0; n < chars; ++n) {
      if (i >= s.size()) return -1;
      const unsigned char c = s[i];
      i += c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
    }
    return i <= s.size() ? static_cast<int>(i) : -1;
  }

  static size_t charCount(const std::string &s) {
    size_t n = 0;
    for (unsigned char c : s) n += (c & 0xc0) != 0x80;
    return n;
  }

  std::unique_ptr<MozcTransport> mozc_;
  std::string rimeUserDir_;
  const bool touch_;
  uint64_t session_ = 0;
  bool direct_ = false;
  CompositionMode kana_ = mozc::commands::HIRAGANA;
  std::string commit_, aux_;
  // The PCs' undo: Mozc's last commit, the text before the caret the next key comes with, and whether it
  // ends with that commit.
  std::string lastCommit_, before_;
  bool undoable_ = false;
  Preedit preedit_;
  Page page_;
  std::vector<int32_t> ids_;
  // The phone's
  Keys keys_ = Keys::Kana;
  bool landscape_ = false, katakana_ = false, learning_ = true, halfWidthSpace_ = false;
  mozc::commands::Context::InputFieldType field_ = mozc::commands::Context::NORMAL;
  std::vector<Candidate> list_;
  std::vector<int32_t> listIds_;
  int focused_ = -1;
  Edit edit_;
};

}  // namespace

std::unique_ptr<Engine> makeMozc(const MozcPaths &paths) { return std::make_unique<Mozc>(paths); }

}  // namespace sebtype
