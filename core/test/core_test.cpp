// The core's riskiest paths with stand-in engines: language switching, the Shift tap, 简/繁, あ ⇄ ア,
// paging 6 to a page, and the phone's 🌐, list and fields.
#include <sebtype/core.h>

#include <gtest/gtest.h>

#ifdef SEBTYPE_ENGLISH
#include <sebtype/hosts.h>

#include <condition_variable>
#include <filesystem>
#include <mutex>
#include <thread>
#endif

using namespace sebtype;
using namespace std::chrono_literals;

namespace {

constexpr uint32_t Shift_L = 0xffe1, Shift_R = 0xffe2, Control_L = 0xffe3, Alt_L = 0xffe9, Super_L = 0xffeb;

// Types letters into a preedit, lists `total` candidates 6 to a page, commits the highlighted one on Space.
struct FakeEngine : Engine {
  std::string typed, commit;
  bool latinOn = false, alt = false;
  int total = 20, cursor = 0;
  std::vector<uint32_t> seen;

  bool key(const Key &k) override {
    seen.push_back(k.sym);
    if (k.release || latinOn) return false;
    if (k.sym >= 'a' && k.sym <= 'z' && !(k.mods & (mod::Ctrl | mod::Alt))) {
      typed += static_cast<char>(k.sym);
      cursor = 0;
      return true;
    }
    if (k.sym == ' ' && !typed.empty()) {
      selectAt(cursor);
      return true;
    }
    return false;
  }
  std::string takeCommit() override { return std::exchange(commit, {}); }
  Preedit preedit() override { return typed.empty() ? Preedit{} : Preedit{{{typed}}, 0}; }
  bool composing() override { return !typed.empty(); }
  void flush() override { commit += typed + "0", typed.clear(); }  // as Rime's commit preview: the first candidate
  void clear() override { typed.clear(); }
  int pageSize() override { return 6; }
  bool candidateAt(int i, Candidate &out) override {
    if (typed.empty() || i < 0 || i >= total) return false;
    out = {typed + std::to_string(i)};
    return true;
  }
  int highlighted() override { return typed.empty() ? -1 : cursor; }
  void selectAt(int i) override {
    Candidate c;
    if (candidateAt(i, c)) commit += c.text, typed.clear();
  }
  void highlightAt(int i) override { cursor = i; }
  bool latin() override { return latinOn; }
  void setLatin(bool on) override {
    if (on) commit += std::exchange(typed, {});
    latinOn = on;
  }
  bool alternate() override { return alt; }
  void setAlternate(bool on) override { alt = on; }
  Field field = Field::Text;
  bool learning = true;
  void setField(Field f) override { field = f; }
  void applySettings(const Settings &, bool learn) override { learning = learn; }
};

struct CoreTest : testing::Test {
  std::chrono::steady_clock::time_point now{};
  std::map<Lang, FakeEngine *> engines;
  Core core{[this](Lang l) -> std::unique_ptr<Engine> {
              if (l == Lang::English) return nullptr;  // the PCs' English: keys go to the app
              auto e = std::make_unique<FakeEngine>();
              engines[l] = e.get();
              return e;
            },
            Settings{}, [this] { return now; }};

  bool press(uint32_t sym, uint32_t mods = 0) { return core.key({sym, mods, false}); }
  bool release(uint32_t sym, uint32_t mods = 0) { return core.key({sym, mods, true}); }
  bool tap(uint32_t sym, uint32_t mods = 0) {
    bool taken = press(sym, mods);
    release(sym, mods);
    return taken;
  }
  void type(const std::string &s) {
    for (char c : s) tap(static_cast<uint32_t>(c));
  }
  void shiftTap(uint32_t sym = Shift_L) {
    press(sym);
    now += 100ms;
    release(sym, mod::Shift);
  }
  void winSpace(int taps = 1) {
    press(Super_L);
    for (int i = 0; i < taps; ++i) tap(' ', mod::Super);
    release(Super_L, mod::Super);
  }
  void chord(uint32_t mods, uint32_t sym) {  // modifiers down, key tapped, modifiers up
    if (mods & mod::Ctrl) press(Control_L);
    if (mods & mod::Shift) press(Shift_L, mods & mod::Ctrl);
    if (mods & mod::Alt) press(Alt_L);
    tap(sym, mods);
    if (mods & mod::Alt) release(Alt_L, mods);
    if (mods & mod::Shift) release(Shift_L, mods);
    if (mods & mod::Ctrl) release(Control_L, mods & mod::Ctrl);
  }
  std::vector<std::string> menuLabels() {
    std::vector<std::string> labels;
    for (const auto &item : core.menu()) labels.push_back(item.kind == MenuItem::Separator ? "-" : item.label);
    return labels;
  }
};

TEST_F(CoreTest, WinSpaceTogglesHomeAndLastOtherLanguage) {
  EXPECT_EQ(core.language(), Lang::English);
  winSpace();
  EXPECT_EQ(core.language(), Lang::Chinese);
  EXPECT_EQ(core.takeNotice(false), "中文");  // Fcitx5's popup, as it read before
  EXPECT_EQ(core.takeNotice(false), "");  // once
  shiftTap();
  EXPECT_EQ(core.takeNotice(true), "abc");
  shiftTap();
  EXPECT_EQ(core.takeNotice(false), "中文");
  winSpace();
  EXPECT_EQ(core.language(), Lang::English);
  EXPECT_EQ(core.takeNotice(true), "en");
  winSpace(2);  // Super held: there and back
  EXPECT_EQ(core.language(), Lang::English);
  core.selectLanguage(Lang::Japanese);  // a menu pick is what Win+Space returns to
  winSpace();
  EXPECT_EQ(core.language(), Lang::English);
  winSpace();
  EXPECT_EQ(core.language(), Lang::Japanese);
  core.selectLanguage(Lang::English);
  winSpace();
  EXPECT_EQ(core.language(), Lang::Japanese);
}

TEST_F(CoreTest, SwitchingCommitsWhatIsTypedAndTheFirstLanguageIsHome) {
  core.setSettings(Settings::parse("[Languages]\nOrder=zh,en\n"));
  EXPECT_EQ(core.language(), Lang::English);  // still on: kept
  winSpace();
  EXPECT_EQ(core.language(), Lang::Chinese);
  type("ni");
  winSpace();
  EXPECT_EQ(core.language(), Lang::English);
  EXPECT_EQ(core.takeCommit(), "ni");  // as its letters, as focus moving away types it in (#301)
  EXPECT_EQ(menuLabels(), (std::vector<std::string>{"中文", "English", "-"}));
  core.setSettings(Settings::parse("[Languages]\nOrder=ja\n"));
  EXPECT_EQ(core.language(), Lang::Japanese);  // English went off
  EXPECT_EQ(Settings::parse("[Languages]\nOrder=ja,en,zh\n").serialize(), "[Languages]\nOrder=ja,en,zh\n");
}

// #277: on the PCs, focus moving away types in what is being typed, as it shows, and leaves nothing behind;
// the phone's clear drops it.
TEST_F(CoreTest, FocusMovingAwayTypesInWhatIsTypedAndClearDropsIt) {
  core.selectLanguage(Lang::Chinese);
  type("ni");
  EXPECT_EQ(core.unfinished(), "ni");
  core.focusOut();
  EXPECT_EQ(core.takeCommit(), "ni");
  EXPECT_FALSE(engines[Lang::Chinese]->composing());
  core.focusOut();
  EXPECT_EQ(core.takeCommit(), "");
  type("hao");
  core.clear();
  EXPECT_EQ(core.takeCommit(), "");
  EXPECT_FALSE(engines[Lang::Chinese]->composing());
}

TEST_F(CoreTest, ShiftTapTogglesEnglishLettersOnlyWhenAlone) {
  shiftTap();  // English: nothing to switch
  EXPECT_EQ(core.language(), Lang::English);
  core.selectLanguage(Lang::Chinese);
  type("ni");
  shiftTap();
  EXPECT_TRUE(core.latin());
  EXPECT_EQ(core.takeCommit(), "ni");  // what was typed goes in as letters
  EXPECT_EQ(core.icon(), "zh-a");
  shiftTap();
  EXPECT_FALSE(core.latin());
  EXPECT_EQ(core.icon(), "zh");

  press(Shift_L);  // Shift+K is a capital, not a switch
  tap('K', mod::Shift);
  release(Shift_L, mod::Shift);
  EXPECT_FALSE(core.latin());
  press(Control_L);  // Ctrl+Shift neither
  press(Shift_L, mod::Ctrl);
  release(Shift_L, mod::Ctrl | mod::Shift);
  release(Control_L, mod::Ctrl);
  EXPECT_FALSE(core.latin());
  press(Shift_L);  // held past the tap limit
  now += 600ms;
  release(Shift_L, mod::Shift);
  EXPECT_FALSE(core.latin());
  // Shift alone never reaches the engine: the core is the one switch.
  for (uint32_t s : engines[Lang::Chinese]->seen) EXPECT_NE(s, Shift_L);
}

TEST_F(CoreTest, CapsLockShowsCapitalA) {
  core.selectLanguage(Lang::Japanese);
  shiftTap();
  EXPECT_EQ(core.icon(), "ja-a");
  tap(0xffe5);  // Caps Lock on
  EXPECT_EQ(core.icon(), "ja-caps");
  tap('a', mod::Lock);
  EXPECT_EQ(core.icon(), "ja-caps");
  tap(0xffe5, mod::Lock);  // and off
  EXPECT_EQ(core.icon(), "ja-a");
}

TEST_F(CoreTest, CtrlShiftFTogglesTraditionalInChineseOnly) {
  chord(mod::Ctrl | mod::Shift, 'F');  // English: reaches the app
  EXPECT_FALSE(core.alternate());
  core.selectLanguage(Lang::Chinese);
  core.takeNotice(false);
  chord(mod::Ctrl | mod::Shift, 'F');
  EXPECT_TRUE(core.alternate());
  EXPECT_EQ(core.takeNotice(false), "");  // no popup, as before
  EXPECT_EQ(menuLabels(), (std::vector<std::string>{"English", "中文", "日本語", "-", "繁 → 简\tCtrl+Shift+F", "-"}));
  chord(mod::Ctrl | mod::Shift, 'f');  // Shift may send the lowercase keysym
  EXPECT_FALSE(core.alternate());
  shiftTap();  // also in its English mode
  chord(mod::Ctrl | mod::Shift, 'F');
  EXPECT_TRUE(core.alternate());
  EXPECT_FALSE(press('f', mod::Ctrl));  // Ctrl+F stays Find
}

TEST(SystemLanguage, FirstLocaleSetPicksItLikeTheConfigurator) {
  auto pick = [](std::map<std::string, const char *> env) {
    return systemLanguage([&](const char *var) { return env.contains(var) ? env[var] : nullptr; });
  };
  EXPECT_EQ(pick({}), Lang::English);
  EXPECT_EQ(pick({{"LANG", "zh_CN.UTF-8"}}), Lang::Chinese);
  EXPECT_EQ(pick({{"LANGUAGE", "ja:en"}, {"LANG", "zh_CN.UTF-8"}}), Lang::Japanese);
  EXPECT_EQ(pick({{"LANGUAGE", ""}, {"LC_ALL", "de_DE.UTF-8"}, {"LANG", "ja_JP.UTF-8"}}), Lang::English);
  EXPECT_EQ(pick({{"LC_MESSAGES", "zh_TW.UTF-8"}, {"LANG", "C.UTF-8"}}), Lang::Chinese);
}

TEST_F(CoreTest, PopupWordsFollowTheSystemLanguage) {
  core.setUiLanguage(Lang::Chinese);
  core.selectLanguage(Lang::Japanese);
  EXPECT_EQ(core.takeNotice(false), "日本語（平假名）");
  core.setUiLanguage(Lang::Japanese);
  core.selectLanguage(Lang::Chinese);
  shiftTap();
  EXPECT_EQ(core.takeNotice(false), "中文（英字）");
}

TEST_F(CoreTest, AltGraveSwitchesKanaBeforeTypingAndNotInEnglish) {
  core.selectLanguage(Lang::Japanese);
  EXPECT_EQ(core.takeNotice(true), "あ (Hiragana)");
  EXPECT_EQ(core.icon(), "hira");
  EXPECT_EQ(menuLabels(), (std::vector<std::string>{"English", "中文", "日本語", "-", "あ → ア\tAlt+`", "-"}));
  chord(mod::Alt, '`');
  EXPECT_EQ(core.icon(), "kata");
  EXPECT_EQ(core.takeNotice(false), "");
  shiftTap();
  chord(mod::Alt, '`');  // English letters stay English
  EXPECT_EQ(core.icon(), "ja-a");
  shiftTap();
  EXPECT_EQ(core.icon(), "kata");
  type("ka");
  EXPECT_FALSE(press('`', mod::Alt));  // while typing it goes to Mozc's own keys
  core.activate({MenuItem::Switch});  // the menu switch
  EXPECT_EQ(core.icon(), "hira");
}

TEST_F(CoreTest, PagesSixCandidatesAndAClickPicksOnThePage) {
  core.selectLanguage(Lang::Chinese);
  type("shi");
  Page p = core.page();
  ASSERT_EQ(p.items.size(), 6u);
  EXPECT_EQ(p.labels, (std::vector<std::string>{"1 ", "2 ", "3 ", "4 ", "5 ", "6 "}));
  EXPECT_FALSE(p.hasPrev);
  EXPECT_TRUE(p.hasNext);
  EXPECT_EQ(p.cursor, 0);
  core.changePage(true);
  p = core.page();
  EXPECT_EQ(p.items.front().text, "shi6");
  EXPECT_TRUE(p.hasPrev);
  core.changePage(true);
  core.changePage(true);  // 20 candidates: the last page holds 2
  p = core.page();
  EXPECT_EQ(p.items.size(), 2u);
  EXPECT_FALSE(p.hasNext);
  core.changePage(true);  // nothing after it
  EXPECT_EQ(core.page().items.front().text, "shi18");
  core.changePage(false);
  core.select(2);  // a click on the page
  EXPECT_EQ(core.takeCommit(), "shi14");
  EXPECT_TRUE(core.page().empty());
}

}  // namespace

TEST_F(CoreTest, GlobeCyclesTheLanguagesThatAreOnAndDropsWhatIsTyped) {
  Settings phone = Settings::parse("[Languages]\nOrder=en,ja,zh\n");
  phone.commitOnSwitch = false;  // the user's choice: 🌐 throws unchosen pinyin away
  core.setSettings(phone);
  core.cycleLanguage();
  EXPECT_EQ(core.language(), Lang::Japanese);
  core.cycleLanguage();
  EXPECT_EQ(core.language(), Lang::Chinese);
  type("ni");
  core.cycleLanguage();  // after the last back to the first
  EXPECT_EQ(core.language(), Lang::English);
  EXPECT_EQ(core.takeCommit(), "");
  EXPECT_FALSE(engines[Lang::Chinese]->composing());

  phone.languages = {Lang::Chinese, Lang::English};
  core.setSettings(phone);
  core.cycleLanguage();
  EXPECT_EQ(core.language(), Lang::Chinese);
  core.cycleLanguage();
  EXPECT_EQ(core.language(), Lang::English);
  EXPECT_FALSE(engines.contains(Lang::Japanese));  // a language that is off never starts
}

TEST_F(CoreTest, TheBarListsCandidatesUnpagedAndATapCommitsOne) {
  core.selectLanguage(Lang::Chinese);
  EXPECT_TRUE(core.candidates(100).empty());
  type("ni");
  const auto all = core.candidates(100);
  ASSERT_EQ(all.size(), 20u);  // past the 6 of a page
  EXPECT_EQ(all[7].text, "ni7");
  EXPECT_EQ(core.candidates(3).size(), 3u);
  EXPECT_EQ(core.highlighted(), 0);
  core.selectCandidate(13);
  EXPECT_EQ(core.takeCommit(), "ni13");
  EXPECT_TRUE(core.candidates(100).empty());
}

TEST_F(CoreTest, AFieldThatMustNotLearnTurnsLearningOffInEveryEngine) {
  core.selectLanguage(Lang::Chinese);
  core.key({'a'});
  core.setField(Field::Password, false);
  EXPECT_EQ(engines[Lang::Chinese]->field, Field::Password);
  EXPECT_FALSE(engines[Lang::Chinese]->learning);
  core.selectLanguage(Lang::Japanese);  // started later: told too
  core.key({'a'});
  EXPECT_EQ(engines[Lang::Japanese]->field, Field::Password);
  EXPECT_FALSE(engines[Lang::Japanese]->learning);
  core.setField(Field::Text, true);
  EXPECT_TRUE(engines[Lang::Chinese]->learning);
  Settings incognito;
  incognito.learning = false;  // the setting wins over a field that may learn
  core.setSettings(incognito);
  EXPECT_FALSE(engines[Lang::Japanese]->learning);
}

TEST(SettingsTest, KeepsOnlyTheOptionsThatAreSet) {
  EXPECT_EQ(Settings{}.serialize(), "[Languages]\nOrder=en,zh,ja\n");
  const std::string conf =
      "[Languages]\nOrder=en,zh\n[Chinese]\nTraditional=true\nEmoji=false\n[Japanese]\nHalfWidthSpace=true\n"
      "[Learning]\nOn=false\n";
  const Settings s = Settings::parse(conf);
  EXPECT_EQ(s.traditional, true);
  EXPECT_FALSE(s.fullWidthPunctuation.has_value());
  EXPECT_EQ(s.emoji, false);
  EXPECT_EQ(s.halfWidthSpace, true);
  EXPECT_FALSE(s.learning);
  EXPECT_EQ(s.serialize(), conf);
}

#ifdef SEBTYPE_ENGLISH
// The English engine on the rebuilt dictionary and the committed model, typing at the keys' centres.
struct EnglishTest : testing::Test {
  std::mutex mutex;
  std::condition_variable cv;
  int readies = 0;
  std::unique_ptr<Engine> en;

  void SetUp() override {
    std::filesystem::remove_all(EN_USER_DIR);
    std::filesystem::create_directories(EN_USER_DIR);
    start();
  }
  void start(std::string model = EN_MODEL) {
    en.reset();
    en = makeEnglish({EN_DICT, 0, 0, model, EN_USER_DIR}, [this] {
      std::lock_guard g(mutex);
      readies++;
      cv.notify_all();
    });
  }
  // Waits for next words after the READY call AFTER, up to a minute (the model loads first).
  bool ready(int after) {
    std::unique_lock l(mutex);
    return cv.wait_for(l, std::chrono::minutes(1), [&] { return readies > after; });
  }
  int readyCount() {
    std::lock_guard g(mutex);
    return readies;
  }
  bool type(const std::string &s) {
    bool taken = true;
    for (char c : s) taken &= en->key({static_cast<uint32_t>(c), 0, false});
    return taken;
  }
  std::vector<std::string> list() {
    std::vector<std::string> out;
    for (const auto &c : en->candidates(20)) out.push_back(c.text);
    return out;
  }
  bool lists(const std::string &word) { return indexOf(word) >= 0; }
  int indexOf(const std::string &word) {
    const auto l = list();
    const auto at = std::ranges::find(l, word);
    return at == l.end() ? -1 : int(at - l.begin());
  }
};

TEST_F(EnglishTest, SpaceCorrectsTyposAndKeepsWords) {
  // Without the model (before it has loaded), AOSP's own rule decides.
  start("");
  type("teh ");
  EXPECT_EQ(en->takeCommit(), "the ");
  type("their ");
  EXPECT_EQ(en->takeCommit(), "their ");
  // With the model: "becuase" is corrected, a capital kept, and the correction listed first, highlighted.
  start();
  type("a");
  en->key({0xff08, 0, false});
  ASSERT_TRUE(ready(0));
  type("Becuase");
  EXPECT_EQ(en->highlighted(), 0);
  EXPECT_EQ(list().at(0), "Because");
  EXPECT_EQ(list().at(1), "Becuase");
  type(" ");
  EXPECT_EQ(en->takeCommit(), "Because ");
  type("is ");
  EXPECT_EQ(en->takeCommit(), "is ");
  // A word typed right after a period ("file.py") stays as typed.
  en->setContext("open file.");
  type("pu ");
  EXPECT_EQ(en->takeCommit(), "pu ");
}

TEST_F(EnglishTest, NextWordsComeFromTheWorkerOnceALetterLoadsTheModel) {
  en->setContext("Thank you very ");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  EXPECT_EQ(readyCount(), 0);  // no model yet: nothing typed
  type("m");
  en->key({0xff08, 0, false});  // BackSpace: nothing typed after "very " again
  ASSERT_TRUE(ready(0));
  EXPECT_TRUE(lists("much")) << testing::PrintToString(list());
  // Text changed meanwhile: the words for the old text don't show.
  en->setContext("Thank you very much. See you ");
  EXPECT_FALSE(lists("much"));
}

TEST_F(EnglishTest, PickedWordsAreLearnedKeptAndForgotten) {
  type("zorbly");
  en->selectAt(indexOf("zorbly"));
  EXPECT_EQ(en->takeCommit(), "zorbly ");
  en->setContext("");
  type("zorbl");
  EXPECT_TRUE(lists("zorbly")) << testing::PrintToString(list());
  // Incognito: picked words are still used but not learned.
  en->applySettings({}, false);
  en->setContext("");
  type("quoxtil");
  en->selectAt(indexOf("quoxtil"));
  en->takeCommit();
  en->setContext("");
  type("quoxti");
  EXPECT_FALSE(lists("quoxtil"));
  // Saved on the engine's end, and read back by the next one.
  start("");
  type("zorbl");
  EXPECT_TRUE(lists("zorbly"));
  en->forget();
  type("zorbl");
  EXPECT_FALSE(lists("zorbly"));
}

// #270: a private field (a private browser window on the PCs, incognito on the phone), as every frontend tells
// the core, uses the words learned before but learns no new ones; a field that may learn learns again.
TEST_F(EnglishTest, APrivateFieldKeepsLearnedWordsAndLearnsNoNewOnes) {
  Core core([this](Lang lang) { return lang == Lang::English ? std::move(en) : nullptr; });
  auto typeIn = [&](const std::string &s) {
    core.setContext("");
    for (char c : s) core.key({static_cast<uint32_t>(c), 0, false});
  };
  auto listed = [&](const std::string &word) {
    const auto all = core.candidates(20);
    const auto at = std::ranges::find(all, word, &Candidate::text);
    return at == all.end() ? -1 : int(at - all.begin());
  };
  auto pick = [&](const std::string &word) {
    typeIn(word);
    core.selectCandidate(listed(word));
    EXPECT_EQ(core.takeCommit(), word + " ");
  };
  auto suggests = [&](const std::string &typed, const std::string &word) {
    typeIn(typed);
    return listed(word) >= 0;
  };
  pick("zorbly");
  core.setField(Field::Text, false);
  EXPECT_FALSE(core.fieldLearning());
  EXPECT_TRUE(suggests("zorbl", "zorbly"));
  pick("quoxtil");
  EXPECT_FALSE(suggests("quoxti", "quoxtil"));
  core.setField(Field::Text, true);
  pick("quoxtil");
  EXPECT_TRUE(suggests("quoxti", "quoxtil"));
}

// #254: an update from today's app brings its learned words (made up: "zorbleq", learned there by a test run).
TEST_F(EnglishTest, TodaysLearnedWordsAreTakenInOnce) {
  en.reset();
  const auto legacy = std::filesystem::path(EN_USER_DIR) / "UserHistoryDictionary.en_US.dict";
  std::filesystem::copy(EN_LEGACY_HISTORY, legacy);
  start("");
  type("zorbl");
  EXPECT_TRUE(lists("zorbleq")) << testing::PrintToString(list());
  EXPECT_FALSE(std::filesystem::exists(legacy));
  // Kept in the engine's own learned words from then on.
  start("");
  type("zorbl");
  EXPECT_TRUE(lists("zorbleq"));
}

TEST_F(EnglishTest, OffensiveWordsAreNeverSuggestedOrLearned) {
  type("fuc");
  EXPECT_FALSE(lists("fuck")) << testing::PrintToString(list());
  en->selectAt(indexOf("fuc"));
  en->takeCommit();
  type("fuck");
  en->selectAt(indexOf("fuck"));  // typed out and picked: still not learned
  en->takeCommit();
  en->setContext("");
  type("fuc");
  EXPECT_FALSE(lists("fuck"));
}

TEST_F(EnglishTest, EmailDomainsFollowTheAt) {
  // In a text field: the domain after "@", never corrected, and no space after it.
  type("me");
  EXPECT_FALSE(type("@"));
  EXPECT_EQ(en->takeCommit(), "me");
  type("gm");
  EXPECT_EQ(list().at(0), "gmail.com");
  EXPECT_EQ(en->highlighted(), -1);
  en->selectAt(0);
  EXPECT_EQ(en->takeCommit(), "gmail.com");
  // In an e-mail field the keys go to the app; the pick replaces what was typed after "@".
  en->setField(Field::Plain);
  EXPECT_FALSE(type("a@ou"));
  EXPECT_EQ(list().at(0), "outlook.com");
  en->selectAt(0);
  EXPECT_EQ(en->takeEdit().deleteBefore, 2);
  EXPECT_EQ(en->takeCommit(), "outlook.com");
  en->setField(Field::Password);
  EXPECT_FALSE(type("teh"));
  EXPECT_TRUE(list().empty());
}

TEST_F(EnglishTest, PunctuationAfterAPickJoinsTheWord) {  // #39
  type("hello");
  en->selectAt(indexOf("hello"));
  EXPECT_EQ(en->takeCommit(), "hello ");
  EXPECT_TRUE(type("."));
  EXPECT_EQ(en->takeEdit().deleteBefore, 1);
  EXPECT_EQ(en->takeCommit(), ". ");
  type("ok ");
  en->takeCommit();
  EXPECT_TRUE(type("."));  // a space typed by hand keeps the period where it is
  EXPECT_EQ(en->takeEdit().deleteBefore, 0);
  EXPECT_EQ(en->takeCommit(), ".");
}

TEST_F(EnglishTest, ThePhonesOptionsTurnCorrectionsOffAddPersonalWordsAndTypeDoubleSpacePeriods) {
  start("");
  Settings s;
  s.autocorrect = false;
  en->applySettings(s, true);
  type("teh ");
  EXPECT_EQ(en->takeCommit(), "teh ");
  s.autocorrect = true;
  s.doubleSpacePeriod = true;
  s.englishWords = {{"zorblax", 250}};
  en->applySettings(s, true);
  type("zorbl");
  EXPECT_TRUE(lists("zorblax"));
  en->clear();
  type("ok ");
  en->takeCommit();
  EXPECT_TRUE(type(" "));
  EXPECT_EQ(en->takeEdit().deleteBefore, 1);
  EXPECT_EQ(en->takeCommit(), ". ");
  EXPECT_TRUE(type(" "));  // a third space is only a space
  EXPECT_EQ(en->takeEdit().deleteBefore, 0);
  EXPECT_EQ(en->takeCommit(), " ");
}
#endif
