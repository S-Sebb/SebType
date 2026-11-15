// SebType on Windows: what the text service in each app and the one SebType server per session say to each
// other over the server's named pipe. One request and one reply per connection. MIT, SebType.
#pragma once

#include <sebtype/types.h>

#include <cstdint>
#include <algorithm>
#include <cstring>
#include <string>
#include <vector>

namespace sebtype::win {

enum class Op : uint8_t {
  Key,       // key, lang (the app's): true in reply.taken when the core took it
  Select,    // index: a click on a candidate of the page
  Page,      // next: the window's page arrows
  FocusIn,   // lang: focus came to a text field of an app in this language
  FocusOut,  // focus left it: what is being typed is dropped
  Language,  // lang: Windows switched to this language's profile
  Menu,      // index: a pick in the tray menu (an item of reply.menu)
  Latin,     // a left click on the tray button: English letters and back
  State,     // nothing, just the state
  Deploy,    // setup or the Configurator changed Rime's settings or data; reply.busy until it is applied
  Sync,      // save learned words and merge the other devices' (Rime's sync); reply.busy until done
  Quit,      // the server exits (setup, the Configurator's forget)
};

struct Request {
  Op op = Op::State;
  Key key;
  int32_t index = 0;
  bool next = false;
  Lang lang = Lang::English;
};

struct Reply {
  bool taken = false;
  std::string commit;
  Preedit preedit;
  Page page;
  std::string aux;
  Lang lang = Lang::English;
  std::string icon;  // pc/icons' name: zh, zh-a, zh-caps, hira, kata, ja-a, ja-caps
  std::vector<MenuItem> menu;
  std::string notice;  // the popup after a switch, once
  bool busy = false;   // Rime is deploying or saving
};

// Little-endian lengths and values, strings as UTF-8.
class Writer {
 public:
  std::string out;
  void u32(uint32_t v) { out.append(reinterpret_cast<const char *>(&v), 4); }
  void i32(int32_t v) { u32(static_cast<uint32_t>(v)); }
  void b(bool v) { out.push_back(v ? 1 : 0); }
  void s(const std::string &v) {
    u32(static_cast<uint32_t>(v.size()));
    out += v;
  }
};

class Reader {
 public:
  explicit Reader(const std::string &in) : in_(in) {}
  bool ok() const { return ok_; }
  uint32_t u32() {
    uint32_t v = 0;
    if (!take(4)) return 0;
    std::memcpy(&v, in_.data() + pos_ - 4, 4);
    return v;
  }
  int32_t i32() { return static_cast<int32_t>(u32()); }
  bool b() { return take(1) && in_[pos_ - 1] != 0; }
  std::string s() {
    const uint32_t n = u32();
    if (!take(n)) return {};
    return in_.substr(pos_ - n, n);
  }

 private:
  bool take(size_t n) {
    ok_ = ok_ && in_.size() - pos_ >= n;
    if (ok_) pos_ += n;
    return ok_;
  }
  const std::string &in_;
  size_t pos_ = 0;
  bool ok_ = true;
};

inline std::string encode(const Request &r) {
  Writer w;
  w.u32(static_cast<uint32_t>(r.op));
  w.u32(r.key.sym), w.u32(r.key.mods), w.b(r.key.release);
  w.i32(r.index), w.b(r.next), w.u32(static_cast<uint32_t>(r.lang));
  return w.out;
}

inline bool decode(const std::string &in, Request &r) {
  Reader rd(in);
  r.op = static_cast<Op>(rd.u32());
  r.key.sym = rd.u32(), r.key.mods = rd.u32(), r.key.release = rd.b();
  r.index = rd.i32(), r.next = rd.b(), r.lang = static_cast<Lang>(rd.u32());
  return rd.ok();
}

inline std::string encode(const Reply &r) {
  Writer w;
  w.b(r.taken), w.s(r.commit);
  w.u32(static_cast<uint32_t>(r.preedit.segments.size()));
  for (const auto &s : r.preedit.segments) w.s(s.text), w.b(s.underline), w.b(s.highlight);
  w.i32(r.preedit.cursor);
  w.u32(static_cast<uint32_t>(r.page.items.size()));
  for (const auto &c : r.page.items) w.s(c.text), w.s(c.comment);
  w.u32(static_cast<uint32_t>(r.page.labels.size()));
  for (const auto &l : r.page.labels) w.s(l);
  w.i32(r.page.cursor), w.b(r.page.hasPrev), w.b(r.page.hasNext);
  w.s(r.aux), w.u32(static_cast<uint32_t>(r.lang)), w.s(r.icon);
  w.u32(static_cast<uint32_t>(r.menu.size()));
  for (const auto &m : r.menu) {
    w.u32(m.kind), w.s(m.label), w.s(m.icon), w.b(m.checked), w.u32(static_cast<uint32_t>(m.lang));
  }
  w.s(r.notice), w.b(r.busy);
  return w.out;
}

inline bool decode(const std::string &in, Reply &r) {
  Reader rd(in);
  r.taken = rd.b(), r.commit = rd.s();
  r.preedit.segments.resize(std::min<uint32_t>(rd.u32(), 1024));
  for (auto &s : r.preedit.segments) s.text = rd.s(), s.underline = rd.b(), s.highlight = rd.b();
  r.preedit.cursor = rd.i32();
  r.page.items.resize(std::min<uint32_t>(rd.u32(), 1024));
  for (auto &c : r.page.items) c.text = rd.s(), c.comment = rd.s();
  r.page.labels.resize(std::min<uint32_t>(rd.u32(), 1024));
  for (auto &l : r.page.labels) l = rd.s();
  r.page.cursor = rd.i32(), r.page.hasPrev = rd.b(), r.page.hasNext = rd.b();
  r.aux = rd.s(), r.lang = static_cast<Lang>(rd.u32()), r.icon = rd.s();
  r.menu.resize(std::min<uint32_t>(rd.u32(), 64));
  for (auto &m : r.menu) {
    m.kind = static_cast<MenuItem::Kind>(rd.u32()), m.label = rd.s(), m.icon = rd.s(), m.checked = rd.b();
    m.lang = static_cast<Lang>(rd.u32());
  }
  r.notice = rd.s(), r.busy = rd.b();
  return rd.ok();
}

}  // namespace sebtype::win
