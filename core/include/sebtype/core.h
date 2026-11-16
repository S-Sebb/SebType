// SebType core: languages and switching, the candidate list, the settings and the tray menu, the same on
// every platform. A frontend feeds it keys and draws what it says. MIT, SebType.
#pragma once

#include <sebtype/engine.h>
#include <sebtype/settings.h>
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
  // The phone's 🌐: the next language that is on, after the last back to the first.
  void cycleLanguage();
  const Settings &settings() const { return settings_; }
  void setSettings(Settings settings);

  std::string takeCommit();
  Preedit preedit();
  Page page();
  std::string aux();
  void select(int indexOnPage);
  void changePage(bool next);
  // Focus left the text field (the PCs, #277): what is being typed goes into it as it shows, as Microsoft's
  // IMEs and Mozc do (pinyin as its letters, Japanese as converted).
  void focusOut();
  // Drops what is being typed (the phone's focus changes, the app's reset on Linux).
  void clear();
  // What focusOut would type in.
  std::string unfinished();
  // Commits what is being typed, as leaving the language with commitOnSwitch does.
  void flush();

  // Touch keyboards (the phone): the candidates as one list, not paged (the bar scrolls up to max), the
  // highlighted one in it, and a tap on one.
  std::vector<Candidate> candidates(int max);
  int highlighted();
  void selectCandidate(int index);
  // The text field: its kind, and whether what is typed in it may be learned (private fields, incognito).
  void setField(Field field, bool learning);
  Field field() const { return field_; }
  // The current engine's edit around its last commit.
  Edit takeEdit();
  // The cursor moved inside what is being typed (to a character from its start); the keys on screen; undo of a commit.
  void moveCursor(int chars);
  void setKeys(Keys keys, bool landscape);
  // English: the keys' rectangles, and the field's text before the cursor when it changed other than by
  // what was typed (Engine::setLayout, Engine::setContext).
  void setLayout(const Layout &layout);
  void setContext(const std::string &before);
  bool undo();
  // Stops a language's engine (the phone frees an idle one; the PCs restart Mozc to read its files again); the
  // next use starts it again.
  void stop(Lang lang);

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
  // The engine only when it runs.
  Engine *running(Lang lang);
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
  std::vector<uint32_t> swallow_;  // releases of keys the core took on press
  std::string commit_;
  bool notice_ = false;
  Field field_ = Field::Text;
  bool fieldLearning_ = true;
  Keys keys_ = Keys::Kana;
  bool landscape_ = false;
  Layout layout_;
};

}  // namespace sebtype
