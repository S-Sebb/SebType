// SebType core: languages and switching, the hotkeys, the tray menu and the settings. MIT, SebType.
#include <sebtype/core.h>

#include <algorithm>
#include <sstream>
#include <utility>

namespace sebtype {

namespace {
namespace ks {
constexpr uint32_t space = 0x20, grave = 0x60, F = 0x46, f = 0x66;
constexpr uint32_t Shift_L = 0xffe1, Shift_R = 0xffe2, Caps_Lock = 0xffe5, ISO_Level3_Shift = 0xfe03;
}  // namespace ks

// Rime's limit for a Shift tap (ascii_composer.cc): a longer press is Shift held, not a switch.
constexpr auto kShiftTap = std::chrono::milliseconds(500);

bool isShift(uint32_t sym) { return sym == ks::Shift_L || sym == ks::Shift_R; }
// Shift, Ctrl, Caps Lock, Meta, Alt, Super, Hyper (0xffe1 to 0xffee) and AltGr.
bool isModifier(uint32_t sym) { return (sym >= 0xffe1 && sym <= 0xffee) || sym == ks::ISO_Level3_Shift; }

// The popup's mode words in English, 中文 and 日本語 (#205), worded as the Configurator words them where it
// names the same mode: English letters (英文字母, 英字) and hiragana (平假名, ひらがな).
struct Words {
  const char *en, *zh, *ja;
  const char *in(Lang ui) const { return ui == Lang::Chinese ? zh : ui == Lang::Japanese ? ja : en; }
};
constexpr Words kRimeLatin{"Latin Mode", "英文字母", "英字"}, kMozcLatin{"Direct", "英文字母", "英字"},
    kKatakana{"Full Katakana", "片假名", "カタカナ"}, kHiragana{"Hiragana", "平假名", "ひらがな"};
}  // namespace

const char *langId(Lang lang) {
  switch (lang) {
    case Lang::Chinese: return "zh";
    case Lang::Japanese: return "ja";
    default: return "en";
  }
}

std::string langName(Lang lang) {
  switch (lang) {
    case Lang::Chinese: return "中文";
    case Lang::Japanese: return "日本語";
    default: return "English";
  }
}

Lang systemLanguage(const std::function<const char *(const char *)> &getenv) {
  for (const char *var : {"LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"}) {
    const char *v = getenv(var);
    std::string_view locale = v ? v : "";
    locale = locale.substr(0, locale.find(':'));  // LANGUAGE lists several, the first preferred
    if (locale.empty()) continue;
    return locale.starts_with("zh") ? Lang::Chinese : locale.starts_with("ja") ? Lang::Japanese : Lang::English;
  }
  return Lang::English;
}

Settings Settings::parse(std::string_view ini) {
  Settings s;
  std::istringstream in{std::string(ini)};
  std::string line, section;
  auto flag = [](std::string_view v) { return v == "true"; };
  while (std::getline(in, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.size() > 1 && line.front() == '[' && line.back() == ']') {
      section = line.substr(1, line.size() - 2);
      continue;
    }
    const auto eq = line.find('=');
    if (eq == std::string::npos) continue;
    const std::string key = line.substr(0, eq), value = line.substr(eq + 1);
    if (section == "Languages" && key == "Order") {
      s.languages.clear();
      std::istringstream ids(value);
      for (std::string id; std::getline(ids, id, ',');) {
        for (Lang l : {Lang::English, Lang::Chinese, Lang::Japanese}) {
          if (id == langId(l) && std::ranges::find(s.languages, l) == s.languages.end()) s.languages.push_back(l);
        }
      }
      if (s.languages.empty()) s.languages.push_back(Lang::English);
    } else if (section == "Chinese") {
      if (key == "Traditional") s.traditional = flag(value);
      else if (key == "FullWidthPunctuation") s.fullWidthPunctuation = flag(value);
      else if (key == "Emoji") s.emoji = flag(value);
    } else if (section == "Japanese" && key == "HalfWidthSpace") {
      s.halfWidthSpace = flag(value);
    } else if (section == "Learning" && key == "On") {
      s.learning = flag(value);
    }
  }
  return s;
}

std::string Settings::serialize() const {
  std::string order;
  for (Lang l : languages) order += (order.empty() ? "" : ",") + std::string(langId(l));
  std::string out = "[Languages]\nOrder=" + order + "\n", chinese;
  auto put = [&](const char *key, const std::optional<bool> &v) {
    if (v) chinese += std::string(key) + "=" + (*v ? "true" : "false") + "\n";
  };
  put("Traditional", traditional);
  put("FullWidthPunctuation", fullWidthPunctuation);
  put("Emoji", emoji);
  if (!chinese.empty()) out += "[Chinese]\n" + chinese;
  if (halfWidthSpace) out += std::string("[Japanese]\nHalfWidthSpace=") + (*halfWidthSpace ? "true" : "false") + "\n";
  if (!learning) out += "[Learning]\nOn=false\n";
  return out;
}

Core::Core(EngineFactory factory, Settings settings, Clock clock)
    : factory_(std::move(factory)), clock_(std::move(clock)) {
  setSettings(std::move(settings));
  lang_ = settings_.languages.front();
}

void Core::setSettings(Settings settings) {
  settings_ = std::move(settings);
  forEachEngine([&](Engine &e) { e.applySettings(settings_, settings_.learning && fieldLearning_); });
  if (settings_.languages.empty()) settings_.languages.push_back(Lang::English);
  const auto &on = settings_.languages;
  const Lang home = on.front();
  if (lastOther_ == home || std::ranges::find(on, lastOther_) == on.end())
    lastOther_ = on.size() > 1 ? on[1] : home;
  if (std::ranges::find(on, lang_) == on.end()) switchTo(home);
}

Engine *Core::engine(Lang lang) {
  auto &e = engines_[lang];
  if (!e) {
    e = factory_(lang);
    if (!e) return nullptr;
    e->applySettings(settings_, settings_.learning && fieldLearning_);
    e->setField(field_);
    e->setKeys(keys_, landscape_);
    if (!layout_.keys.empty()) e->setLayout(layout_);
  }
  return e.get();
}

Engine *Core::running(Lang lang) {
  auto it = engines_.find(lang);
  return it == engines_.end() ? nullptr : it->second.get();
}

void Core::forEachEngine(const std::function<void(Engine &)> &fn) {
  for (auto &[lang, e] : engines_)
    if (e) fn(*e);
}

void Core::switchTo(Lang lang) {
  if (lang == lang_) return;
  if (settings_.commitOnSwitch) flush();
  else if (auto *e = running(lang_)) e->clear();
  lang_ = lang;
  if (lang != settings_.languages.front()) lastOther_ = lang;
  notice_ = true;
}

void Core::selectLanguage(Lang lang) { switchTo(lang); }

void Core::toggleLanguage() {
  const Lang home = settings_.languages.front();
  if (lang_ != home) switchTo(home);
  else if (lastOther_ != home) switchTo(lastOther_);
}

void Core::cycleLanguage() {
  const auto &on = settings_.languages;
  auto it = std::ranges::find(on, lang_);
  switchTo(it == on.end() || ++it == on.end() ? on.front() : *it);
}

void Core::flush() {
  if (auto *e = running(lang_)) {
    e->flush();
    commit_ += e->takeCommit();
  }
}

std::vector<Candidate> Core::candidates(int max) {
  auto *e = current();
  return e ? e->candidates(max) : std::vector<Candidate>{};
}

int Core::highlighted() {
  auto *e = current();
  return e ? e->highlighted() : -1;
}

void Core::selectCandidate(int index) {
  if (auto *e = current()) {
    e->selectAt(index);
    commit_ += e->takeCommit();
  }
}

void Core::setField(Field field, bool learning) {
  field_ = field;
  fieldLearning_ = learning;
  forEachEngine([&](Engine &e) {
    e.setField(field);
    e.applySettings(settings_, settings_.learning && learning);
  });
}

Edit Core::takeEdit() {
  auto *e = running(lang_);
  return e ? e->takeEdit() : Edit{};
}

void Core::moveCursor(int chars) {
  if (auto *e = current()) e->moveCursor(chars);
}

void Core::setKeys(Keys keys, bool landscape) {
  keys_ = keys;
  landscape_ = landscape;
  forEachEngine([&](Engine &e) { e.setKeys(keys, landscape); });
}

void Core::setLayout(const Layout &layout) {
  layout_ = layout;
  forEachEngine([&](Engine &e) { e.setLayout(layout); });
}

void Core::setContext(const std::string &before) {
  if (auto *e = current()) e->setContext(before);
}

bool Core::undo() {
  auto *e = current();
  if (!e || !e->undo()) return false;
  commit_ += e->takeCommit();
  return true;
}

void Core::stop(Lang lang) { engines_.erase(lang); }

bool Core::key(const Key &k) {
  if (k.sym == ks::Caps_Lock) {
    if (!k.release) capsLock_ = !(k.mods & mod::Lock);  // the state before this press
  } else {
    capsLock_ = k.mods & mod::Lock;
  }
  Engine *e = current();

  if (k.release) {
    if (auto it = std::ranges::find(swallow_, k.sym); it != swallow_.end()) {
      swallow_.erase(it);
      return true;
    }
    if (isShift(k.sym) && shiftDown_ == k.sym) {
      shiftDown_ = 0;
      if (e && clock_() - shiftAt_ <= kShiftTap && e->shiftTapSwitches(k.sym)) {
        e->setLatin(!e->latin());
        commit_ += e->takeCommit();
        notice_ = lang_ == Lang::Chinese;
        return true;
      }
      return false;
    }
  } else if (isShift(k.sym) && !(k.mods & (mod::Ctrl | mod::Alt | mod::Super))) {
    shiftDown_ = k.sym;
    shiftAt_ = clock_();
  } else {
    shiftDown_ = 0;
  }

  auto take = [&] {
    swallow_.push_back(k.sym);
    return true;
  };
  const uint32_t chord = k.mods & (mod::Shift | mod::Ctrl | mod::Alt | mod::Super);
  if (!k.release) {
    if (k.sym == ks::space && (k.mods & mod::Super)) {
      toggleLanguage();
      return take();
    }
    // 简/繁 at any time, also in Chinese's English mode (#36).
    if (lang_ == Lang::Chinese && e && (k.sym == ks::F || k.sym == ks::f) && chord == (mod::Ctrl | mod::Shift)) {
      setAlternate(!e->alternate());
      return take();
    }
    // あ ⇄ ア before typing; English letters stay English (Decisions #2, menu hotkeys).
    if (lang_ == Lang::Japanese && e && k.sym == ks::grave && chord == mod::Alt && !e->latin() && !e->composing()) {
      setAlternate(!e->alternate());
      return take();
    }
  }
  if (!e || (isModifier(k.sym) && k.sym != ks::Caps_Lock)) return false;
  const bool wasLatin = e->latin();
  const bool taken = e->key(k);
  commit_ += e->takeCommit();
  if (e->latin() != wasLatin && lang_ == Lang::Chinese) notice_ = true;  // Rime's Caps Lock switch
  return taken;
}

// What Fcitx5's popup read for fcitx5-rime, fcitx5-mozc and the keyboard, as setup-ime.sh named them
// (Instance::showInputMethodInformation): the label in compact mode, else the name, and the submode in
// brackets. Only 中文's English mode had a short submode label, which compact mode shows alone.
std::string Core::takeNotice(bool compact) {
  if (!std::exchange(notice_, false)) return {};
  Engine *e = current();
  std::string name = compact ? (lang_ == Lang::English ? "en" : lang_ == Lang::Japanese ? "あ" : "中文") : langName(lang_);
  const Words *subMode = nullptr;
  if (e && lang_ == Lang::Chinese && e->latin()) {
    if (compact) return capsLock_ ? "ABC" : "abc";
    subMode = &kRimeLatin;
  } else if (e && lang_ == Lang::Japanese) {
    subMode = e->latin() ? &kMozcLatin : e->alternate() ? &kKatakana : &kHiragana;
  }
  if (!subMode) return name;
  // Full-width brackets in 中文 and 日本語, as the Configurator writes 读音（平假名）.
  return ui_ == Lang::English ? name + " (" + subMode->en + ")" : name + "（" + subMode->in(ui_) + "）";
}

std::string Core::takeCommit() { return std::exchange(commit_, {}); }

Preedit Core::preedit() {
  auto *e = current();
  return e ? e->preedit() : Preedit{};
}

Page Core::page() {
  auto *e = current();
  return e ? e->page() : Page{};
}

std::string Core::aux() {
  auto *e = current();
  return e ? e->aux() : std::string{};
}

void Core::select(int indexOnPage) {
  if (auto *e = current()) {
    e->select(indexOnPage);
    commit_ += e->takeCommit();
  }
}

void Core::changePage(bool next) {
  if (auto *e = current()) e->changePage(next);
}

void Core::focusOut() {
  commit_ += unfinished();
  clear();
}

std::string Core::unfinished() {
  auto *e = running(lang_);
  return e ? e->unfinished() : std::string{};
}

void Core::clear() {
  shiftDown_ = 0;
  swallow_.clear();
  if (auto *e = running(lang_)) e->clear();
}

bool Core::latin() {
  auto *e = current();
  return e && e->latin();
}

bool Core::alternate() {
  auto *e = current();
  return e && e->alternate();
}

void Core::setAlternate(bool on) {
  if (auto *e = current()) {
    e->setAlternate(on);
    commit_ += e->takeCommit();
  }
}

std::string Core::icon() {
  auto *e = current();
  switch (lang_) {
    case Lang::Chinese:
      if (e && e->latin()) return capsLock_ ? "zh-caps" : "zh-a";
      return "zh";
    case Lang::Japanese:
      if (e && e->latin()) return capsLock_ ? "ja-caps" : "ja-a";
      return e && e->alternate() ? "kata" : "hira";
    default:
      return "en";
  }
}

std::vector<MenuItem> Core::menu() {
  std::vector<MenuItem> items;
  for (Lang l : settings_.languages) {
    items.push_back({MenuItem::Language, langName(l), l == Lang::Chinese ? "zh" : l == Lang::Japanese ? "hira" : "en",
                     l == lang_, l});
  }
  items.push_back({});
  // The language's one switch with its key (#117).
  std::string label;
  if (lang_ == Lang::Chinese) label = alternate() ? "繁 → 简\tCtrl+Shift+F" : "简 → 繁\tCtrl+Shift+F";
  if (lang_ == Lang::Japanese) label = alternate() ? "ア → あ\tAlt+`" : "あ → ア\tAlt+`";
  if (!label.empty()) {
    items.push_back({MenuItem::Switch, label});
    items.push_back({});
  }
  return items;
}

void Core::activate(const MenuItem &item) {
  if (item.kind == MenuItem::Language) selectLanguage(item.lang);
  else if (item.kind == MenuItem::Switch) setAlternate(!alternate());
}

}  // namespace sebtype
