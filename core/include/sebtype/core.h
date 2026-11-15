// SebType core: languages and switching, the candidate list, the settings and the tray menu, the same on
// every platform. A frontend feeds it keys and draws what it says. MIT, SebType.
#pragma once

#include <sebtype/engine.h>
#include <sebtype/types.h>

#include <chrono>
#include <cstdlib>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace sebtype {

// The settings the Configurator writes for the core (Rime's and Mozc's own stay in their files).
struct Settings {
  // Languages that are on, in tray-menu order. The first is Win+Space's home language (#93).
  std::vector<Lang> languages{Lang::English, Lang::Chinese, Lang::Japanese};

  static Settings parse(std::string_view ini);
  std::string serialize() const;
};

const char *langId(Lang lang);  // en, zh, ja
std::string langName(Lang lang);  // English, 中文, 日本語
// The system's language, as the Configurator picks it (#118): the first locale set in LANGUAGE, LC_ALL,
// LC_MESSAGES or LANG, when it is 中文 or 日本語; English for any other.
Lang systemLanguage(const std::function<const char *(const char *)> &getenv = std::getenv);

class Core {
 public:
  using EngineFactory = std::function<std::unique_ptr<Engine>(Lang)>;
  using Clock = std::function<std::chrono::steady_clock::time_point()>;

  explicit Core(EngineFactory factory, Settings settings = {}, Clock clock = std::chrono::steady_clock::now);

  // True when the key was taken; then read commit, preedit and page.
  bool key(const Key &key);

  Lang language() const { return lang_; }
  // A pick in the tray menu: it also becomes the language Win+Space returns to.
  void selectLanguage(Lang lang);
  // Win+Space: the home language ⇄ the last other one.
  void toggleLanguage();
  const Settings &settings() const { return settings_; }
  void setSettings(Settings settings);

  std::string takeCommit();
  Preedit preedit();
  Page page();
  std::string aux();
  void select(int indexOnPage);
  void changePage(bool next);
  // Focus left the text field: what is being typed is dropped.
  void focusOut();

  bool latin();
  bool alternate();
  void setAlternate(bool on);
  bool capsLock() const { return capsLock_; }
  // The tray icon: en, zh, zh-a, zh-caps, hira, kata, ja-a, ja-caps (the names in pc/icons).
  std::string icon();
  std::vector<MenuItem> menu();
  void activate(const MenuItem &item);
  // The popup after a switch of language or of 中文's English mode, once, as Fcitx5 showed it
  // (compact: its CompactInputMethodInformation); empty when there is none.
  std::string takeNotice(bool compact);
  // The language the popup's words are in (#205); English until set.
  void setUiLanguage(Lang lang) { ui_ = lang; }

  // The engine of a language, started on first use; nullptr for English.
  Engine *engine(Lang lang);
  // Every started engine.
  void forEachEngine(const std::function<void(Engine &)> &fn);

 private:
  Engine *current() { return engine(lang_); }
  void switchTo(Lang lang);

  EngineFactory factory_;
  Settings settings_;
  Clock clock_;
  std::map<Lang, std::unique_ptr<Engine>> engines_;
  Lang lang_ = Lang::English;
  Lang ui_ = Lang::English;
  Lang lastOther_ = Lang::English;
  bool capsLock_ = false;
  uint32_t shiftDown_ = 0;  // the Shift key pressed alone, until another key comes
  std::chrono::steady_clock::time_point shiftAt_;
  uint32_t shiftTime_ = 0;  // its Key::time
  std::vector<uint32_t> swallow_;  // releases of keys the core took on press
  std::string commit_;
  bool notice_ = false;
};

}  // namespace sebtype
