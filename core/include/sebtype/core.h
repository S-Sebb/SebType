// SebType core: languages and switching, the candidate list, the settings and the tray menu, the same on
// every platform. A frontend feeds it keys and draws what it says. MIT, SebType.
#pragma once

#include <sebtype/engine.h>
#include <sebtype/not_ready.h>
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
  // Commits what is being typed as the engine would (the phone's 🌐 key in an app's own field).
  void flush();
  // Commits the keys typed as they are, the letters before pinyin or kana (the phone's 🌐, #492).
  void flushInput();

  // Touch keyboards (the phone): the candidates as one list, not paged (the bar scrolls up to max), the
  // highlighted one in it, and a tap on one.
  std::vector<Candidate> candidates(int max);
  int highlighted();
  // Engine::settle on the current engine.
  bool settle();
  void selectCandidate(int index);
  // The text field: its kind, and whether what is typed in it may be learned (private fields, incognito).
  void setField(Field field, bool learning);
  Field field() const { return field_; }
  bool fieldLearning() const { return fieldLearning_; }
  // The current engine's edit around its last commit.
  Edit takeEdit();
  // The cursor moved inside what is being typed (to a character from its start); the keys on screen; undo of a commit.
  void moveCursor(int chars);
  void setKeys(Keys keys, bool landscape);
  // English: the keys' rectangles, and the field's text around the cursor when it changed other than by
  // what was typed (Engine::setLayout, Engine::setContext).
  void setLayout(const Layout &layout);
  void setContext(const std::string &before, const std::string &after = {}, bool selection = false);
  bool undo();
  // Stops a language's engine (the phone frees an idle one; the PCs restart Mozc to read its files again); the
  // next use starts it again.
  void stop(Lang lang);

  // Work that drops what is being typed, asked for by a sync or the Configurator (#373): Rime's deploy and
  // save, Mozc reading its files again. It waits until typing is idle (nothing being typed, no key for kIdle,
  // no engine busy), so a sync never takes a word being typed (Decisions #2). One asked for again while it
  // waits is done once; several are done in this order.
  enum class Chore { Deploy, ReloadJapanese, Save };
  static constexpr std::chrono::seconds kIdle{5};
  void whenIdle(Chore chore, std::function<void()> work);
  // Does the next chore that waits, if typing is idle; the frontend calls it again while it returns true.
  bool runChores();
  bool choresWait() const { return !chores_.empty(); }

  bool latin();
  bool alternate();
  void setAlternate(bool on);
  bool capsLock() const { return capsLock_; }
  // The tray icon: en, zh, zh-a, zh-caps, hira, kata, ja-a, ja-caps, and zh-wait, zh-off, hira-wait, hira-off
  // while the language isn't ready (the names in pc/icons).
  std::string icon();
  // Whether the language's engine takes keys now; keys it can't take go to the app as typed (#275).
  Readiness readiness();
  // Another language's icon, read only: an engine not started yet is ready (a text service in another
  // language's app asks while this one types, #275).
  std::string icon(Lang lang);
  std::vector<MenuItem> menu();
  void activate(const MenuItem &item);
  // The popup after a switch of language or of 中文's English mode, once, as Fcitx5 showed it
  // (compact: its CompactInputMethodInformation), or at the first key typed while the language isn't ready;
  // empty when there is none.
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
  std::string icon(Lang lang, Engine *e);
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
  std::chrono::steady_clock::time_point lastKey_;  // or the start, before any
  std::map<Chore, std::function<void()>> chores_;
  std::vector<uint32_t> swallow_;  // releases of keys the core took on press
  std::string commit_;
  bool notice_ = false;
  Readiness notReady_ = Readiness::Ready;  // the popup says so (#275)
  bool warned_ = false;  // said once until the language is ready again
  Field field_ = Field::Text;
  bool fieldLearning_ = true;
  Keys keys_ = Keys::Kana;
  bool landscape_ = false;
  Layout layout_;
};

}  // namespace sebtype
