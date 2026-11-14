// SPDX-License-Identifier: BSD-3-Clause
// SebType core: 日本語 through Mozc's own mozc_server, over Mozc's IPC. The key translation, the candidate
// window and the server's protocol use follow fcitx5-mozc (Copyright 2010-2018 Google Inc. and 2017 Weng
// Xuetian; fcitx/mozc's src/unix/fcitx5), so this file keeps its licence: see core/README.md.
#include <sebtype/hosts.h>

#ifndef _WIN32
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <map>
#include <thread>
#include <utility>

#include "ipc/ipc.pb.h"
#include "protocol/commands.pb.h"

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

// Mozc's IPC: one connection per call to the server named after the key it writes to
// <profile>/.session.ipc. On Linux an abstract Unix socket, the request ending at the write shutdown; on
// Windows a message-mode named pipe, one message each way (Mozc's ipc/win32_ipc.cc).
class Ipc {
 public:
  explicit Ipc(MozcPaths paths) : paths_(std::move(paths)) {}

  bool call(const Input &in, Output &out) {
    std::string request;
    in.SerializeToString(&request);
    std::string reply;
    if (!send(request, reply)) {
      launch();
      bool sent = false;
      for (int i = 0; i < 60 && !sent; ++i) {  // up to 3 s for a fresh server
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        sent = send(request, reply);
      }
      if (!sent) return false;
    }
    return out.ParseFromString(reply);
  }

 private:
  std::string key() {
    std::ifstream f(std::filesystem::u8path(paths_.profileDir + "/.session.ipc"), std::ios::binary);
    mozc::ipc::IPCPathInfo info;
    if (!f || !info.ParseFromIstream(&f)) return {};
    return info.key();
  }

#ifdef _WIN32
  bool send(const std::string &request, std::string &reply) {
    const std::string key = this->key();
    if (key.empty()) return false;
    const std::string name = "\\\\.\\pipe\\mozc." + key + ".session";
    HANDLE pipe = CreateFileA(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                              SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return false;
    DWORD mode = PIPE_READMODE_MESSAGE, n = 0;
    bool ok = SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr) &&
              WriteFile(pipe, request.data(), static_cast<DWORD>(request.size()), &n, nullptr) &&
              n == request.size();
    reply.clear();
    char buf[65536];
    for (bool more = ok; more;) {
      more = false;
      if (ReadFile(pipe, buf, sizeof(buf), &n, nullptr)) {
        reply.append(buf, n);
      } else if (GetLastError() == ERROR_MORE_DATA) {
        reply.append(buf, n);
        more = true;
      } else {
        ok = false;
      }
    }
    CloseHandle(pipe);
    return ok;
  }

  // Starts mozc_server on its own, as Mozc's client does: it outlives the host and stops when idle.
  void launch() {
    std::wstring cmd = L"\"" + std::filesystem::u8path(paths_.server).wstring() + L"\"";
    STARTUPINFOW si{sizeof(si)};
    PROCESS_INFORMATION pi{};
    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE,
                       CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_DEFAULT_ERROR_MODE, nullptr, nullptr, &si, &pi)) {
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    }
  }
#else
  bool send(const std::string &request, std::string &reply) {
    const std::string key = this->key();
    if (key.empty()) return false;
    const std::string name = "tmp/.mozc." + key + ".session";
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path + 1, name.data(), std::min(name.size(), sizeof(addr.sun_path) - 1));
    const socklen_t len = sizeof(addr.sun_family) + 1 + name.size();
    timeval timeout{5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    bool ok = connect(fd, reinterpret_cast<sockaddr *>(&addr), len) == 0;
    for (size_t sent = 0; ok && sent < request.size();) {
      ssize_t n = write(fd, request.data() + sent, request.size() - sent);
      ok = n > 0;
      sent += ok ? n : 0;
    }
    ok = ok && shutdown(fd, SHUT_WR) == 0;
    reply.clear();
    char buf[65536];
    for (ssize_t n; ok && (n = read(fd, buf, sizeof(buf))) != 0;) {
      ok = n > 0;
      if (ok) reply.append(buf, n);
    }
    close(fd);
    return ok;
  }

  // Starts mozc_server on its own, as Mozc's client does: it outlives Fcitx5 and stops when idle.
  void launch() {
    pid_t pid = fork();
    if (pid == 0) {
      if (fork() == 0) {
        setsid();
        int null = open("/dev/null", O_RDWR);
        dup2(null, 0), dup2(null, 1), dup2(null, 2);
        execl(paths_.server.c_str(), paths_.server.c_str(), static_cast<char *>(nullptr));
      }
      _exit(0);
    }
    if (pid > 0) waitpid(pid, nullptr, 0);
  }
#endif

  MozcPaths paths_;
};

class Mozc final : public Engine {
 public:
  explicit Mozc(const MozcPaths &paths) : ipc_(paths) {}

  ~Mozc() override {
    if (!session_) return;
    Input in;
    in.set_type(Input::DELETE_SESSION);
    in.set_id(session_);
    Output out;
    ipc_.call(in, out);
  }

  bool key(const Key &k) override {
    if (k.release) return false;
    Input in;
    in.set_type(Input::SEND_KEY);
    if (!translate(k, *in.mutable_key())) return false;
    // In English letters only the keys that may turn Japanese on (Hankaku/Zenkaku, Kana…) go to the server.
    if (direct_ && !isImeKey(in.key())) return false;
    in.mutable_key()->set_mode(kana_);
    return send(in);
  }

  std::string takeCommit() override { return std::exchange(commit_, {}); }
  Preedit preedit() override { return preedit_; }
  std::string aux() override { return aux_; }
  bool composing() override { return !preedit_.empty(); }

  void flush() override { command(SessionCommand::SUBMIT); }
  void clear() override {
    if (!preedit_.empty() || !page_.empty()) command(SessionCommand::REVERT);
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
    ensureSession();
    return kana_ == mozc::commands::FULL_KATAKANA || kana_ == mozc::commands::HALF_KATAKANA;
  }
  // あ ⇄ ア, from English letters too (the menu switch).
  void setAlternate(bool on) override {
    SessionCommand c;
    c.set_type(direct_ ? SessionCommand::TURN_ON_IME : SessionCommand::SWITCH_COMPOSITION_MODE);
    c.set_composition_mode(on ? mozc::commands::FULL_KATAKANA : mozc::commands::HIRAGANA);
    command(c);
  }

  void save() override {
    Input in;
    in.set_type(Input::SYNC_DATA);
    Output out;
    ipc_.call(in, out);
  }

 private:
  bool ensureSession() {
    if (session_) return true;
    Input in;
    in.set_type(Input::CREATE_SESSION);
    in.mutable_capability()->set_text_deletion(mozc::commands::Capability::DELETE_PRECEDING_TEXT);
    in.mutable_application_info()->set_process_id(getpid());
    Output out;
    if (!ipc_.call(in, out) || !out.has_id()) return false;
    session_ = out.id();
    SessionCommand on;  // Japanese starts in あ
    on.set_type(SessionCommand::TURN_ON_IME);
    on.set_composition_mode(mozc::commands::HIRAGANA);
    return command(on);
  }

  void command(SessionCommand::CommandType type) {
    SessionCommand c;
    c.set_type(type);
    command(c);
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
      if (ipc_.call(in, out) && out.error_code() == Output::SESSION_SUCCESS) return parse(out);
      session_ = 0;
    }
    return false;
  }

  // fcitx5-mozc's MozcResponseParser.
  bool parse(const Output &out) {
    if (out.has_status()) {
      direct_ = !out.status().activated();
      if (out.status().mode() != mozc::commands::DIRECT) kana_ = out.status().mode();
    } else if (out.has_mode()) {
      direct_ = out.mode() == mozc::commands::DIRECT;
      if (!direct_) kana_ = out.mode();
    }
    if (!out.consumed()) return false;
    if (out.has_result()) commit_ += out.result().value();
    preedit_ = {};
    if (out.has_preedit()) {
      std::string text;
      for (const auto &s : out.preedit().segment()) {
        text += s.value();
        preedit_.segments.push_back({s.value(), s.annotation() == mozc::commands::Preedit::Segment::UNDERLINE,
                                     s.annotation() == mozc::commands::Preedit::Segment::HIGHLIGHT});
      }
      const uint32_t pos = out.preedit().has_highlighted_position() ? out.preedit().highlighted_position()
                                                                    : out.preedit().cursor();
      preedit_.cursor = byteOffset(text, pos);
    }
    page_ = {};
    ids_.clear();
    aux_.clear();
    if (out.has_candidate_window()) parseCandidates(out.candidate_window());
    return true;
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

  Ipc ipc_;
  uint64_t session_ = 0;
  bool direct_ = false;
  CompositionMode kana_ = mozc::commands::HIRAGANA;
  std::string commit_, aux_;
  Preedit preedit_;
  Page page_;
  std::vector<int32_t> ids_;
};

}  // namespace

std::unique_ptr<Engine> makeMozc(const MozcPaths &paths) { return std::make_unique<Mozc>(paths); }

}  // namespace sebtype
