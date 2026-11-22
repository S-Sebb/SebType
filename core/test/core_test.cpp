// The core's riskiest paths with stand-in engines: language switching, the Shift tap, 简/繁, あ ⇄ ア,
// paging 6 to a page, and the phone's 🌐, list and fields.
#include <sebtype/core.h>

#include <gtest/gtest.h>

#if defined(SEBTYPE_ENGLISH) || defined(SEBTYPE_CHINESE_MODEL)
#include <sebtype/hosts.h>
#ifdef SEBTYPE_ENGLISH
#include <sebtype_lm.h>
#endif

#include <condition_variable>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <set>
#include <thread>

#include <unistd.h>
#endif

using namespace sebtype;
using namespace std::chrono_literals;

namespace {

constexpr uint32_t Shift_L = 0xffe1, Shift_R = 0xffe2, Control_L = 0xffe3, Alt_L = 0xffe9, Super_L = 0xffeb;

// Types letters into a preedit, lists `total` candidates 6 to a page, commits the highlighted one on Space.
struct FakeEngine : Engine {
  std::string typed, commit;
  bool latinOn = false, alt = false, deploying = false, loaded = true;
  int total = 20, cursor = 0;
  std::vector<uint32_t> seen;

  bool key(const Key &k) override {
    seen.push_back(k.sym);
    if (k.release || latinOn || deploying || !loaded) return false;
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
  bool busy() override { return deploying; }
  bool available() override { return loaded; }
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

// The keys that end the popup on Linux and Windows (#449): a typed key, not the switch's own keys or a modifier.
TEST(TypesText, TypedKeysButNotModifiersShortcutsOrReleases) {
  EXPECT_TRUE(typesText({'a'}));
  EXPECT_TRUE(typesText({'A', mod::Shift}));
  EXPECT_TRUE(typesText({'1'}));
  EXPECT_FALSE(typesText({'a', 0, true}));
  EXPECT_FALSE(typesText({' ', mod::Super}));  // Win+Space
  EXPECT_FALSE(typesText({Super_L, mod::Super, true}));
  EXPECT_FALSE(typesText({Shift_L}));
  EXPECT_FALSE(typesText({'c', mod::Ctrl}));
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

// #489: a switch back to 中文 or 日本語 types the language, not the Shift tap's English it was left in; ア stays.
TEST_F(CoreTest, SwitchingBackEndsTheShiftTapsEnglish) {
  core.selectLanguage(Lang::Japanese);
  core.setAlternate(true);
  shiftTap();
  winSpace();
  winSpace();
  EXPECT_EQ(core.language(), Lang::Japanese);
  EXPECT_FALSE(core.latin());
  EXPECT_EQ(core.icon(), "kata");
  core.selectLanguage(Lang::Chinese);
  shiftTap();
  core.selectLanguage(Lang::English);
  core.selectLanguage(Lang::Chinese);
  EXPECT_EQ(core.icon(), "zh");
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

// #275: while Rime deploys (or Mozc didn't load) the key is grey, keys go to the app as typed, and the first
// one says why, once until the language is ready again; then the key is 中 or あ again.
TEST_F(CoreTest, ALanguageThatIsNotReadyGreysItsKeyAndSaysSoOnce) {
  core.selectLanguage(Lang::Chinese);
  core.takeNotice(false);
  engines[Lang::Chinese]->deploying = true;
  EXPECT_EQ(core.icon(), "zh-wait");
  EXPECT_FALSE(tap('n'));
  EXPECT_EQ(core.takeNotice(true), "中文 is getting ready: letters go in as typed");
  EXPECT_FALSE(tap('i'));
  chord(mod::Ctrl, 'c');
  EXPECT_EQ(core.takeNotice(false), "");
  engines[Lang::Chinese]->deploying = false;
  EXPECT_EQ(core.icon(), "zh");
  EXPECT_TRUE(tap('n'));
  EXPECT_EQ(core.takeNotice(false), "");
  engines[Lang::Chinese]->clear();
  engines[Lang::Chinese]->deploying = true;  // a second deploy says it again
  tap('h');
  EXPECT_EQ(core.takeNotice(false), "中文 is getting ready: letters go in as typed");

  core.setUiLanguage(Lang::Chinese);
  core.selectLanguage(Lang::Japanese);
  core.takeNotice(false);
  engines[Lang::Japanese]->loaded = false;
  EXPECT_EQ(core.icon(), "hira-off");
  EXPECT_FALSE(tap('k'));
  EXPECT_EQ(core.takeNotice(false), "日本語暂不可用 · 按英文字母输入");

  // A 中文 app's text service asks while a 日本語 one is typing: the answer changes nothing.
  engines[Lang::Japanese]->loaded = true;
  type("ka");
  EXPECT_EQ(core.icon(Lang::Chinese), "zh-wait");
  EXPECT_EQ(core.icon(Lang::Japanese), "hira");
  EXPECT_EQ(core.language(), Lang::Japanese);
  EXPECT_EQ(core.preedit().segments.size(), 1u);
}

// #373: a sync's save, a deploy or Mozc's reload drops what is being typed, so each waits until typing is idle:
// nothing typed, no key for Core::kIdle and no engine busy; then they run one at a time, in Chore's order.
TEST_F(CoreTest, ChoresWaitUntilTypingIsIdle) {
  core.selectLanguage(Lang::Chinese);
  type("ni");
  FakeEngine &zh = *engines[Lang::Chinese];
  std::vector<std::string> done;
  core.whenIdle(Core::Chore::Save, [&] { done.push_back("save"), zh.clear(); });  // Rime's save ends its session
  core.whenIdle(Core::Chore::Deploy, [&] { done.push_back("deploy"), zh.deploying = true; });
  core.whenIdle(Core::Chore::Save, [&] { done.push_back("save"), zh.clear(); });  // asked again: done once
  now += 1h;
  EXPECT_TRUE(core.runChores());  // a word is being typed
  type("hao");
  EXPECT_EQ(core.preedit().text(), "nihao");
  tap(' ');
  now += 4s;
  EXPECT_TRUE(core.runChores());  // the last key was too recent
  EXPECT_TRUE(done.empty());
  now += 1s;
  EXPECT_TRUE(core.runChores());
  EXPECT_EQ(done, (std::vector<std::string>{"deploy"}));
  EXPECT_TRUE(core.runChores());  // Rime deploys
  zh.deploying = false;
  EXPECT_FALSE(core.runChores());
  EXPECT_EQ(done, (std::vector<std::string>{"deploy", "save"}));
  EXPECT_EQ(core.takeCommit(), "nihao0");
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
      "[Candidates]\nPinyinRow=0\n[Learning]\nOn=false\n";
  const Settings s = Settings::parse(conf);
  EXPECT_EQ(s.traditional, true);
  EXPECT_FALSE(s.fullWidthPunctuation.has_value());
  EXPECT_EQ(s.emoji, false);
  EXPECT_EQ(s.halfWidthSpace, true);
  EXPECT_FALSE(s.pinyinRow);
  EXPECT_TRUE(Settings{}.pinyinRow);
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
  void start(std::string model = EN_MODEL, std::chrono::milliseconds rankDelay = {}) {
    en.reset();
    en = makeEnglish({EN_DICT, 0, 0, model, EN_USER_DIR, rankDelay}, [this] {
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
  // Each key and then its suggestions, as the phone's keyboard asks for them
  bool type(const std::string &s) {
    bool taken = true;
    for (char c : s) {
      taken &= en->key({static_cast<uint32_t>(c), 0, false});
      en->settle();
    }
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
  const int readies = readyCount();
  type("Becuase");
  ASSERT_TRUE(ready(readies));  // the model's ranking, which the list waits for (#450)
  EXPECT_EQ(list().at(0), "Because");
  EXPECT_EQ(list().at(1), "Becuase");
  EXPECT_EQ(en->highlighted(), 0);  // of the list shown
  type(" ");
  EXPECT_EQ(en->takeCommit(), "Because ");
  type("is ");
  EXPECT_EQ(en->takeCommit(), "is ");
  // A word typed right after a period ("file.py") stays as typed.
  en->setContext("open file.");
  type("pu ");
  EXPECT_EQ(en->takeCommit(), "pu ");
}

// A letter shows the decoder's strip at once and the model ranks it on the worker (#310); a space typed
// right after the letters, before that ranking has come, waits for it and corrects by the model.
TEST_F(EnglishTest, ASpaceBeforeTheModelsRankingWaitsForIt) {
  start("");
  type("waht ");
  EXPECT_EQ(en->takeCommit(), "want ");  // the decoder's rule
  start();
  type("a");
  en->key({0xff08, 0, false});
  ASSERT_TRUE(ready(0));
  type("waht ");
  EXPECT_EQ(en->takeCommit(), "what ");
}

// A key changes the list once (#450): its own result and the decoder's leave the list shown as it was, and
// the model's ranking, expected within the hold, takes its place.
TEST_F(EnglishTest, AKeyChangesTheListOnceToTheModelsRanking) {
  start(EN_MODEL, std::chrono::milliseconds(50));
  type("a");
  en->key({0xff08, 0, false});
  ASSERT_TRUE(ready(0));
  const int readies = readyCount();
  type("wah");
  ASSERT_TRUE(ready(readies));  // the model's ranking for "wah"
  const auto before = list();
  en->key({'t', 0, false});
  EXPECT_EQ(list(), before);  // the key's own result
  en->settle();
  EXPECT_EQ(list(), before);  // not the decoder's, "want" first
  for (int i = 0; i < 100 && list() == before; i++) std::this_thread::sleep_for(20ms);
  EXPECT_EQ(list().at(0), "what");
  // A tap while the list is kept picks the word shown, in place of the letters typed since.
  const auto shown = list();
  en->key({'s', 0, false});
  en->settle();
  ASSERT_EQ(list(), shown);
  en->selectAt(0);
  EXPECT_EQ(en->takeCommit(), "what ");
  // After a space the word's list stays until the model's next words, and a tap on it meanwhile does nothing.
  type("is");
  for (int i = 0; i < 100 && !lists("is"); i++) std::this_thread::sleep_for(20ms);
  const auto word = list();
  ASSERT_TRUE(lists("is"));
  type(" ");
  EXPECT_EQ(en->takeCommit(), "is ");
  EXPECT_EQ(list(), word);
  en->selectAt(0);
  EXPECT_EQ(en->takeCommit(), "");
  for (int i = 0; i < 100 && list() == word; i++) std::this_thread::sleep_for(20ms);
  const auto next = list();
  std::this_thread::sleep_for(300ms);
  EXPECT_EQ(list(), next);  // one change, not the dictionaries' words and then the model's
}

// A tap picks the word shown, even when the model's ranking has come since and moved another word there.
TEST_F(EnglishTest, ATapPicksTheWordShownNotALaterRanking) {
  start(EN_MODEL, std::chrono::milliseconds(300));
  type("a");
  en->key({0xff08, 0, false});
  ASSERT_TRUE(ready(0));
  int readies = readyCount();
  type("waht");  // timed: rankings take longer than the list waits for them (#450)
  ASSERT_TRUE(ready(readies));
  en->key({0xff08, 0, false});
  type("t");
  const auto shown = list();  // the decoder's: the model's "what" isn't ranked yet
  ASSERT_EQ(shown.at(0), "want");
  readies = readyCount();
  ASSERT_TRUE(ready(readies));  // ranked, not shown
  en->selectAt(0);
  EXPECT_EQ(en->takeCommit(), "want ");
}

// Rankings known to take longer than a space may wait: the space doesn't wait, and the decoder's rule decides.
TEST_F(EnglishTest, ASpaceDoesntWaitForRankingsKnownToBeSlow) {
  start(EN_MODEL, std::chrono::milliseconds(1000));
  type("a");
  en->key({0xff08, 0, false});
  ASSERT_TRUE(ready(0));
  int readies = readyCount();
  type("waht");  // timed: rankings take a second
  ASSERT_TRUE(ready(readies));
  en->key({0xff08, 0, false});
  type("t");  // ranked again, a second from now
  const auto start = std::chrono::steady_clock::now();
  type(" ");
  EXPECT_LT(std::chrono::steady_clock::now() - start, std::chrono::milliseconds(200));
  EXPECT_EQ(en->takeCommit(), "want ");
}

TEST_F(EnglishTest, NextWordsComeFromTheWorkerOnceALetterLoadsTheModel) {
  en->setContext("Thank you very ");
  std::this_thread::sleep_for(std::chrono::milliseconds(300));
  EXPECT_EQ(readyCount(), 0);  // no model yet: nothing typed
  type("m");
  en->key({0xff08, 0, false});  // BackSpace: nothing typed after "very " again
  ASSERT_TRUE(ready(0));
  EXPECT_TRUE(lists("much")) << testing::PrintToString(list());
  // Text changed meanwhile: the words for the old text give way to the new text's.
  const int readies = readyCount();
  en->setContext("Thank you very much. See you ");
  ASSERT_TRUE(ready(readies));
  EXPECT_FALSE(lists("much"));
}

// The model reads a window of the text before the cursor whose start stays put while the text grows, so a
// long field's next words decode only the new words (#359).
TEST(EnglishModel, ALongContextPredictsAsItsWindowAloneAndEditsEarlierTextAgain) {
  sebtype_lm::Model model(EN_MODEL), fresh(EN_MODEL);
  // The same words with the same probabilities, to within what decoding in other batches changes (~0.02).
  auto same = [](const std::vector<sebtype_lm::Word> &a, const std::vector<sebtype_lm::Word> &b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++)
      if (a[i].word != b[i].word || std::abs(a[i].logProb - b[i].logProb) > 0.1f) return false;
    return true;
  };
  std::string filler;
  while (filler.size() < 20000) filler += "The quick brown fox jumps over the lazy dog. ";
  const std::string text = filler + "Thank you very";
  const std::string window = model.window(text);
  EXPECT_LE(window.size(), 300u);
  EXPECT_TRUE(text.ends_with(" " + window));
  const auto before = model.nextWords(text, 5);
  // The start stays as the text grows, also when the engine cuts the field's text at another place.
  const std::string more = text + " much for the";
  EXPECT_EQ(model.window(more), window + " much for the");
  EXPECT_EQ(model.window(more.substr(more.size() - 1000)), window + " much for the");
  EXPECT_TRUE(same(before, fresh.nextWords(window, 5)));
  // Earlier text inside the window changed: the cache holds the old text's words, which must not count.
  std::string edited = text;
  edited.replace(edited.rfind("dog."), 4, "cat!");
  ASSERT_EQ(model.window(edited).size(), window.size());
  const auto after = model.nextWords(edited, 5);
  EXPECT_FALSE(same(after, before));  // the edit changes the prediction, so a stale cache would show
  EXPECT_TRUE(same(after, sebtype_lm::Model(EN_MODEL).nextWords(edited, 5)));
}

// Learning is the decoder's: without the model, whose ranking the list would wait for (#450).
TEST_F(EnglishTest, PickedWordsAreLearnedKeptAndForgotten) {
  start("");
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
  start("");  // learning is the decoder's, as above
  Core core([this](Lang lang) { return lang == Lang::English ? std::move(en) : nullptr; });
  auto typeIn = [&](const std::string &s) {
    core.setContext("");
    for (char c : s) core.key({static_cast<uint32_t>(c), 0, false}), core.settle();
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

// #280: Backspace right after a correction puts back what was typed, as today's app (AOSP's revertCommit):
// after a space the word is open again, never corrected, and the space comes back before the next word.
TEST_F(EnglishTest, BackspaceRightAfterACorrectionPutsBackWhatWasTyped) {
  start("");
  type("teh ");
  EXPECT_EQ(en->takeCommit(), "the ");
  EXPECT_TRUE(en->key({0xff08, 0, false}));
  EXPECT_EQ(en->takeEdit().deleteBefore, 4);
  EXPECT_EQ(en->takeCommit(), "");
  EXPECT_EQ(en->preedit().text(), "teh");
  en->settle();
  EXPECT_TRUE(lists("the"));
  EXPECT_EQ(en->highlighted(), -1);
  type("x");  // the next word, after the space the revert took
  EXPECT_EQ(en->takeCommit(), "teh ");
  EXPECT_EQ(en->preedit().text(), "x");
  en->clear();
  // Punctuation stays after the word.
  type("teh.");
  EXPECT_EQ(en->takeCommit(), "the.");
  EXPECT_TRUE(en->key({0xff08, 0, false}));
  EXPECT_EQ(en->takeEdit().deleteBefore, 4);
  EXPECT_EQ(en->takeCommit(), "teh.");
  EXPECT_FALSE(en->composing());
  // A space keeps the word as typed.
  type("teh ");
  en->takeCommit();
  en->key({0xff08, 0, false});
  en->takeEdit();
  type(" ");
  EXPECT_EQ(en->takeCommit(), "teh ");
  // As in today's app, the space comes back before a digit or a symbol too ("teh 1"), and before a double
  // quote that opens; not before ' (it joins the word) or a word separator such as "(", and after .,;:!?)]}
  // it waits for the next character.
  for (const auto &[keys, commit, preedit] :
       {std::tuple{"1", "teh ", ""}, {"@", "teh ", ""}, {"\"", "teh \"", ""}, {"(", "teh", ""}, {"'", "", "teh'"},
        {")x", "teh) ", "x"}, {")1", "teh) ", ""}}) {
    en.reset();  // saves what it learned: "teh", from the revert before
    SetUp();     // a fresh user dictionary
    start("");
    type("teh ");
    ASSERT_EQ(en->takeCommit(), "the ");
    en->key({0xff08, 0, false});
    ASSERT_EQ(en->takeEdit().deleteBefore, 4);
    type(keys);
    EXPECT_EQ(en->takeCommit(), commit) << keys;
    EXPECT_EQ(en->preedit().text(), preedit) << keys;
  }
  auto revertAfter = [&](const std::string &before) {
    en.reset();
    SetUp();
    start("");
    en->setContext(before, "");
    type("teh ");
    ASSERT_EQ(en->takeCommit(), "the ");
    en->key({0xff08, 0, false});
    ASSERT_EQ(en->takeEdit().deleteBefore, 4);
  };
  // Only ASCII's apostrophe joins the word: a curly one gets the space ("teh ’").
  revertAfter("");
  en->key({0x1000000 + U'’', 0, false});
  EXPECT_EQ(en->takeCommit(), "teh ");
  EXPECT_EQ(en->preedit().text(), "’");
  // A double quote right before a letter of any script closes a quote, as Java's Character.isLetter has it
  // ("Ж\"teh"): the next one opens another, after the space.
  revertAfter("Ж\"");
  type("\"");
  EXPECT_EQ(en->takeCommit(), "teh \"");
}

// Only the key right after the correction undoes it: not once another key came, the cursor moved, the
// field changed or the word was picked. Backspace then deletes as before (and reopens the word it reaches).
TEST_F(EnglishTest, BackspaceAfterACorrectionUndoesItOnlyRightAfter) {
  start("");
  auto backspaceReverts = [&] {
    en->takeCommit();
    en->key({0xff08, 0, false});
    const Edit e = en->takeEdit();
    return e.deleteBefore > 0 || en->takeCommit() == "teh ";
  };
  type("teh ");
  type("a");
  en->key({0xff08, 0, false});
  EXPECT_FALSE(backspaceReverts());
  EXPECT_EQ(en->preedit().text(), "the");  // the space went, and the word the cursor reached is open
  en->clear();
  type("teh ");
  en->setContext("the ", "");
  EXPECT_FALSE(backspaceReverts());
  en->clear();
  type("teh ");
  en->setField(Field::Text);
  EXPECT_FALSE(backspaceReverts());
  en->clear();
  type("teh");
  en->selectAt(indexOf("the"));
  EXPECT_FALSE(backspaceReverts());
}

// #280: the cursor put back into a word reopens it, with its suggestions and no correction, as today's app.
TEST_F(EnglishTest, ACursorPutIntoAWordReopensIt) {
  start("");
  en->setContext("I like teh", " cat");
  Edit e = en->takeEdit();
  EXPECT_TRUE(e.recompose);
  EXPECT_EQ(e.composeBefore, 3);
  EXPECT_EQ(e.composeAfter, 0);
  EXPECT_EQ(en->preedit().text(), "teh");
  EXPECT_TRUE(lists("the"));
  type(" ");
  EXPECT_EQ(en->takeCommit(), "teh ");
  // Inside it: the whole word, and a pick replaces it all.
  en->setContext("I like t", "eh cat");
  e = en->takeEdit();
  EXPECT_EQ(e.composeBefore, 1);
  EXPECT_EQ(e.composeAfter, 2);
  EXPECT_EQ(en->preedit().text(), "teh");
  en->selectAt(indexOf("the"));
  EXPECT_EQ(en->takeCommit(), "the");  // the space after it in the field stays the only one
  EXPECT_EQ(en->takeEdit().cursor, 1);
  // A letter typed inside it goes in at the cursor, with the letters before it.
  en->setContext("I like t", "eh cat");
  en->takeEdit();
  type("o");
  e = en->takeEdit();
  EXPECT_TRUE(e.recompose);
  EXPECT_EQ(e.composeBefore, 1);
  EXPECT_EQ(e.composeAfter, 0);
  EXPECT_EQ(en->preedit().text(), "to");
  // Not with text selected, nor in a password field.
  en->setContext("I like teh", "", true);
  EXPECT_FALSE(en->composing());
  en->setField(Field::Password);
  en->setContext("I like teh", "");
  EXPECT_FALSE(en->composing());
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

// #380: a personal word's shortcut offers it first, as in the FUTO-based app, but a space never replaces the
// shortcut typed with it, with the model or without; not even with a dictionary word the main dictionary
// would correct it to (the FUTO-based app's space typed "becuase" with this shortcut, "because" without).
// Letters near a shortcut offer its word first too when the decoder ranks it first, as there; otherwise
// they correct as usual ("becaus" to "because", with the shortcut or without).
TEST_F(EnglishTest, APersonalWordsShortcutOffersItWithoutCorrectingToIt) {
  Settings s;
  s.englishWords = {{"plimbo vexter", 250, "qvz"}, {"because", 250, "becuase"}};
  for (const std::string model : {"", EN_MODEL}) {
    const int readies = readyCount();
    start(model);
    en->applySettings(s, true);
    if (!model.empty()) {  // the model ranks once it has loaded
      type("a");
      en->key({0xff08, 0, false});
      ASSERT_TRUE(ready(readies));
    }
    // At a sentence's start the phone types it with a capital, and the word comes capitalised too.
    for (const auto &[typed, word, committed] :
         {std::tuple{"qvz", "plimbo vexter", "qvz "}, {"Qvz", "Plimbo vexter", "Qvz "},
          {"qvx", "plimbo vexter", "qvx "}, {"becuase", "because", "becuase "}, {"becaus", "", "because "}}) {
      const std::string letters = typed;
      type(letters.substr(0, letters.size() - 1));
      const int ranked = readyCount();
      type(letters.substr(letters.size() - 1));
      if (!model.empty()) ASSERT_TRUE(ready(ranked));  // the model's ranking, which would put the phrase last
      if (*word) EXPECT_EQ(indexOf(word), 1) << testing::PrintToString(list());  // after the typed word
      type(" ");
      EXPECT_EQ(en->takeCommit(), committed) << model;
      en->clear();
    }
  }
}

// A personal word that is also another one's shortcut stays a word, whichever comes first (#380).
TEST_F(EnglishTest, APersonalWordThatIsAlsoAShortcutStaysAWord) {
  start("");
  const PersonalWord word{"zorblax", 250, ""}, phrase{"plimbo vexter", 250, "zorblax"};
  for (const auto &words : {std::vector{word, phrase}, std::vector{phrase, word}}) {
    Settings s;
    s.englishWords = words;
    en->applySettings(s, true);
    type("zorbl");
    EXPECT_TRUE(lists("zorblax")) << testing::PrintToString(list());
    en->clear();
    type("zorblax");
    EXPECT_TRUE(lists("plimbo vexter")) << testing::PrintToString(list());
    en->clear();
  }
}
#endif

#ifdef SEBTYPE_CHINESE_MODEL
// Rime as the model sees it: a few words by their pinyin, a candidate list for the input not yet chosen
// (FULL's sentence for all of it first, marked as one, then the words that start it, longest first), and picks that consume
// their letters, committing and learning once the whole input is chosen. 繁 turns 爱 into 愛. A flush commits
// what Rime previews, its first candidate, and learns nothing. A first candidate in LEARNED comes marked as
// learned, as Rime's data marks a word from its user dictionary. FIXES are its corrections by input (#478).
struct FakeRime : Engine {
  std::map<std::string, std::vector<std::string>> words{
      {"wo", {"我", "握"}}, {"ai", {"爱", "挨"}}, {"ni", {"你", "泥"}}, {"hao", {"好"}}, {"nihao", {"你好"}}};
  std::map<std::string, std::string> full{{"woaini", "握挨泥"}, {"nihao", "你好"}};
  std::string in, chosen, commit;
  size_t done = 0;
  bool alt = false;
  std::vector<int> picks;
  std::vector<std::string> learned;
  std::set<std::string> userWords;
  std::map<std::string, std::vector<std::string>> fixes;
  int corrected = 0;  // corrections() asked

  struct Item {
    std::string text;
    size_t letters;
  };
  std::string shown(std::string t) const {
    if (alt)
      for (size_t at; (at = t.find("爱")) != std::string::npos;) t.replace(at, 3, "愛");
    return t;
  }
  std::vector<Item> list() const {
    std::vector<Item> out;
    const std::string left = in.substr(done);
    if (left.empty()) return out;
    if (auto f = full.find(left); f != full.end()) out.push_back({shown(f->second), left.size()});
    for (size_t n = left.size(); n > 0; n--)
      if (auto w = words.find(left.substr(0, n)); w != words.end())
        for (const auto &t : w->second) out.push_back({shown(t), n});
    return out;
  }
  bool key(const Key &k) override {
    if (k.release) return false;
    if (k.sym >= 'a' && k.sym <= 'z') return in += char(k.sym), true;
    if (k.sym == 0xff08 && !in.empty()) return in.pop_back(), true;
    if (k.sym == ' ' && composing()) return selectAt(0), true;
    if (k.sym == ',' && composing()) selectAt(0);
    if (k.sym == ',') return commit += "，", true;
    return false;
  }
  std::string takeCommit() override { return std::exchange(commit, {}); }
  // "wo ai ni": the syllables by the longest words that spell the input
  Preedit preedit() override {
    if (in.empty()) return {};
    std::string syl;
    for (size_t i = done; i < in.size();) {
      size_t n = std::min<size_t>(3, in.size() - i);
      while (n > 1 && !words.count(in.substr(i, n))) n--;
      syl += (syl.empty() ? "" : " ") + in.substr(i, n);
      i += n;
    }
    Preedit p;
    if (!chosen.empty()) p.segments.push_back({chosen, true, false});
    p.segments.push_back({syl, true, true});
    return p;
  }
  std::string input() override { return in; }
  bool composing() override { return !in.empty(); }
  void flush() override {
    if (const auto l = list(); !l.empty()) commit += chosen + l[0].text + in.substr(done + l[0].letters);
    else commit += chosen + in.substr(done);
    clear();
  }
  void clear() override { in.clear(), chosen.clear(), done = 0; }
  int pageSize() override { return 6; }
  bool candidateAt(int i, Candidate &out) override {
    const auto l = list();
    if (i < 0 || i >= int(l.size())) return false;
    // FULL's text for the input is a sentence, unless it is one of the input's words too
    const std::string left = in.substr(done);
    const auto w = words.find(left);
    const bool sentence = i == 0 && full.count(left) && full.at(left) == l[i].text &&
                          (w == words.end() || std::ranges::find(w->second, l[i].text) == w->second.end());
    out = {l[i].text, {}, i == 0 && userWords.count(l[i].text) > 0, sentence};
    return true;
  }
  int highlighted() override { return composing() ? 0 : -1; }
  void selectAt(int i) override {
    const auto l = list();
    if (i < 0 || i >= int(l.size())) return;
    picks.push_back(i);
    chosen += l[i].text;
    done += l[i].letters;
    if (done == in.size()) learned.push_back(chosen), commit += chosen, clear();
  }
  bool latin() override { return false; }
  void setLatin(bool) override {}
  bool alternate() override { return alt; }
  void setAlternate(bool on) override { alt = on; }
  bool corrects() override { return !fixes.empty(); }
  std::vector<Candidate> corrections(const std::string &letters, int max) override {
    corrected++;
    std::vector<Candidate> out;
    for (const auto &t : fixes[letters])
      if (int(out.size()) < max) out.push_back({t, {}});
    return out;
  }
};

// The model around FakeRime, with the committed model and the system's OpenCC tables.
struct ChineseTest : testing::Test {
  std::mutex mutex;
  std::condition_variable cv;
  int readies = 0;
  FakeRime *rime = nullptr;
  std::unique_ptr<Engine> zh;

  void SetUp() override { start(); }
  void start(std::chrono::milliseconds delay = {}, std::function<void(FakeRime &)> setUp = {}, bool nextWords = true) {
    zh.reset();
    auto r = std::make_unique<FakeRime>();
    if (setUp) setUp(*r);
    rime = r.get();
    // The characters' readings, as rime-data's sebtype_readings.txt has them: FakeRime's words, and 当 (dang).
    const auto readings = std::filesystem::temp_directory_path() / ("sebtype-readings-" + std::to_string(getpid()));
    {
      std::ofstream out(readings);
      out << "当\tdang\n";
      for (const auto &words : {FakeRime().words, r->words})
        for (const auto &[letters, texts] : words)
          for (const auto &t : texts)
            if (t.size() == 3) out << t << '\t' << letters << '\n';  // one Han character
    }
    ChineseModelPaths paths{ZH_MODEL, ZH_OPENCC, 1, delay};
    paths.readings = readings;
    paths.nextWords = nextWords;
    zh = withChineseModel(std::move(r), paths, [this] {
      std::lock_guard g(mutex);
      readies++;
      cv.notify_all();
    });
  }
  int readyCount() {
    std::lock_guard g(mutex);
    return readies;
  }
  // Waits for the READY call after AFTER, up to a minute (the model loads first).
  bool ready(int after) {
    std::unique_lock l(mutex);
    return cv.wait_for(l, std::chrono::minutes(1), [&] { return readies > after; });
  }
  void type(const std::string &s) {
    for (char c : s) zh->key({static_cast<uint32_t>(c), 0, false});
  }
  // Types S and waits for the model's list.
  void typeAndWait(const std::string &s) {
    const int before = readyCount();
    type(s);
    ASSERT_TRUE(ready(before));
  }
  std::vector<std::string> list() {
    std::vector<std::string> out;
    for (const auto &c : zh->candidates(20)) out.push_back(c.text);
    return out;
  }
};

TEST_F(ChineseTest, TheModelsOwnCandidateComesFirstAndTeachesRime) {
  typeAndWait("woaini");
  // The model's own candidate first, then Rime's sentence; Space picks it, and Rime learns it piece by
  // piece: 我 (wo), 爱 (ai), 你 (ni).
  const auto l = list();
  ASSERT_GE(l.size(), 2u);
  EXPECT_EQ(l[0], "我爱你");
  EXPECT_NE(std::ranges::find(l, "握挨泥"), l.end());
  EXPECT_EQ(zh->highlighted(), 0);
  zh->key({' ', 0, false});
  EXPECT_EQ(zh->takeCommit(), "我爱你");
  EXPECT_EQ(rime->learned, (std::vector<std::string>{"我爱你"}));
  EXPECT_EQ(rime->picks.size(), 3u);
  EXPECT_FALSE(zh->composing());
}

// The model's own candidates that read the letters otherwise (#503): for "dan" it adds 当 (dang), as it was
// trained to read n as ng and a last syllable cut short; it comes after Rime's first two pages for dan.
TEST_F(ChineseTest, TheModelsMisreadingsComeAfterRimesFirstPages) {
  start({}, [](FakeRime &r) { r.words["dan"] = {"但", "单", "弹", "蛋", "🥚", "淡", "丹", "氮", "胆", "担"}; });
  typeAndWait("dan");
  const auto l = list();
  const auto dang = std::ranges::find(l, "当");
  for (const char *s : {"但", "单", "弹", "蛋", "淡"}) EXPECT_LT(std::ranges::find(l, s), dang) << s << " " << testing::PrintToString(l);
}

// Behind a sentence Rime pieced together (诞, made up as one here) a misreading keeps its place: there the
// model's other readings are mostly typo fixes (#503).
TEST_F(ChineseTest, AMisreadingKeepsItsPlaceBehindASentence) {
  start({}, [](FakeRime &r) {
    r.words["dan"] = {"但", "单", "弹", "蛋", "🥚", "淡", "丹", "氮", "胆", "担"};
    r.full["dan"] = "诞";
  });
  typeAndWait("dan");
  const auto l = list();
  EXPECT_LT(std::ranges::find(l, "当"), std::ranges::find(l, "淡")) << testing::PrintToString(l);
}

// Paging and the arrow keys move the highlight within the model's list (#367): its order stays, and what
// Space or a flush commits is the candidate highlighted there.
TEST_F(ChineseTest, TheHighlightMovesWithinTheModelsList) {
  start({}, [](FakeRime &r) { r.words["wo"] = {"我", "握", "窝", "卧", "沃"}; });  // a second page
  typeAndWait("woaini");
  const auto l = list();
  ASSERT_EQ(l.at(0), "我爱你");
  const int rimes = int(std::ranges::find(l, "握挨泥") - l.begin());
  ASSERT_LT(rimes, int(l.size()));
  zh->highlightAt(rimes);
  EXPECT_EQ(list(), l);
  EXPECT_EQ(zh->highlighted(), rimes);
  zh->flush();
  EXPECT_EQ(zh->takeCommit(), "握挨泥");

  zh->setContext("", "", false);
  typeAndWait("woaini");
  ASSERT_EQ(list(), l);
  ASSERT_GT(l.size(), 6u);
  zh->changePage(true);
  EXPECT_EQ(zh->highlighted(), 6);
  EXPECT_EQ(zh->page().items.at(0).text, l[6]);
  // A digit past the last page's end picks nothing, not Rime's candidate there on its own first page
  ASSERT_LT(l.size(), 12u);
  zh->key({static_cast<uint32_t>('1' + l.size() - 6), 0, false});
  EXPECT_EQ(zh->takeCommit(), "");
  EXPECT_TRUE(zh->composing());
  EXPECT_EQ(list(), l);
  EXPECT_EQ(zh->highlighted(), 6);
  zh->key({0xff55, 0, false});  // Page Up
  zh->key({0xff54, 0, false});  // Down
  zh->key({0xff52, 0, false});  // Up
  EXPECT_EQ(zh->highlighted(), 0);
  EXPECT_EQ(list(), l);
  zh->key({' ', 0, false});
  EXPECT_EQ(zh->takeCommit(), "我爱你");
  EXPECT_EQ(rime->learned.back(), "我爱你");
}

TEST_F(ChineseTest, PickingRimesCandidateSelectsItByRimesIndex) {
  typeAndWait("nihao");
  const auto l = list();
  const auto at = std::ranges::find(l, "你好");
  ASSERT_NE(at, l.end());
  zh->selectAt(int(at - l.begin()));
  EXPECT_EQ(rime->picks, (std::vector<int>{0}));  // Rime's first, 你好 for all of it
  EXPECT_EQ(zh->takeCommit(), "你好");
}

TEST_F(ChineseTest, ALateListNeverShows) {
  start(300ms);  // each list takes 0.3 s longer
  typeAndWait("nihao");
  zh->clear();
  int before = readyCount();
  type("wo");
  type("a");  // asked for "wo", then "woa": only the last comes
  zh->clear();
  type("woaini");
  EXPECT_EQ(list().at(0), "握挨泥");  // Rime's, until the model's for these letters
  ASSERT_TRUE(ready(before));
  EXPECT_EQ(readyCount(), before + 1);
  EXPECT_EQ(list().at(0), "我爱你");
}

// A key changes the list once (#450): Rime's list for the new letters doesn't show before the model's, which
// is expected within the hold.
TEST_F(ChineseTest, AKeyChangesTheListOnceToTheModels) {
  start(50ms);
  typeAndWait("woain");
  const auto before = list();
  const int readies = readyCount();
  type("i");
  EXPECT_EQ(list(), before);  // not Rime's, 握挨泥 first
  ASSERT_TRUE(ready(readies));
  const auto shown = list();
  EXPECT_EQ(shown.at(0), "我爱你");
  // After a commit the list stays until the model's next words, and a tap on it meanwhile does nothing.
  zh->key({' ', 0, false});
  EXPECT_EQ(zh->takeCommit(), "我爱你");
  EXPECT_EQ(list(), shown);
  zh->selectAt(0);
  EXPECT_EQ(zh->takeCommit(), "");
  for (int i = 0; i < 100 && list() == shown; i++) std::this_thread::sleep_for(20ms);
  const auto next = list();
  std::this_thread::sleep_for(300ms);
  EXPECT_EQ(list(), next);  // one change, not an empty list and then the next words
  EXPECT_FALSE(next.empty());
}

// The phone's setup self-test reads the list at once after its keys (#467): Rime's, never a list the hold
// (#450) kept from before, which would fail it once the model has come quickly.
TEST_F(ChineseTest, TheSelfTestSeesRimesListAtOnce) {
  typeAndWait("woaini");
  const auto l = zh->tryTyping("ni", 20, Field::Text);
  ASSERT_FALSE(l.empty());
  EXPECT_EQ(l[0].text, "你");
  EXPECT_FALSE(zh->composing());
  EXPECT_EQ(zh->takeCommit(), "");
}

// A tap while the list is kept (#450) picks the word shown, not Rime's candidate in its place.
TEST_F(ChineseTest, ATapWhileTheListIsKeptPicksTheWordShown) {
  start(50ms);
  typeAndWait("woain");
  const auto shown = list();
  type("i");
  ASSERT_EQ(list(), shown);
  const auto rimes = rime->candidates(20);
  size_t i = 0;
  while (i < shown.size() && i < rimes.size() && shown[i] == rimes[i].text) i++;
  ASSERT_LT(i, shown.size());
  zh->selectAt(int(i));
  EXPECT_TRUE((zh->takeCommit() + zh->preedit().text()).starts_with(shown[i])) << shown[i];
}

// Typos that read as valid pinyin (#478). The model's list shows first, untouched; on the turn its second
// READY asks for, Rime's corrections are looked up, and once the model has weighed them the list changes
// again if the correction moves. yu for yue: the model reads 越来越小 itself. yoou for you: the model's own beam
// misses 又快又好, but is nearly as sure of it as of its own first once asked, so the correction goes first.
struct ChineseFixTest : ChineseTest {
  void SetUp() override { startFixing(); }
  void startFixing(std::chrono::milliseconds delay = {}) {
    start(delay, [](FakeRime &r) {
      r.words.insert({{"yue", {"越"}}, {"lai", {"来"}}, {"yu", {"鱼"}}, {"xiao", {"小"}}, {"you", {"有"}},
                      {"kuai", {"块"}}});
      r.full["yuelaiyuxiao"] = "越来鱼小";
      r.fixes["yuelaiyuxiao"] = {"越来越小", "越来越少"};
      r.full["youkuaiyoouhao"] = "有块友好";
      r.fixes["youkuaiyoouhao"] = {"又快又好", "有快有好"};
    });
  }
};

TEST_F(ChineseFixTest, TheReportedSlipReadsAsMeant) {
  const int before = readyCount();
  type("yuelaiyuxiao");
  ASSERT_TRUE(ready(before + 1));
  EXPECT_EQ(list().at(0), "越来越小");
  zh->key({' ', 0, false});
  EXPECT_EQ(zh->takeCommit(), "越来越小");
}

TEST_F(ChineseFixTest, ANearlyAsLikelyCorrectionComesFirst) {
  const int before = readyCount();
  type("youkuaiyoouhao");
  ASSERT_TRUE(ready(before + 1));  // the model's list, then the turn for corrections
  const auto shown = list();
  EXPECT_EQ(rime->corrected, 0);  // not while making the list that shows first
  ASSERT_NE(shown.at(0), "又快又好");
  const int asked = readyCount();
  EXPECT_EQ(list(), shown);  // the turn: the same list, and the corrections looked up
  EXPECT_EQ(rime->corrected, 1);
  ASSERT_TRUE(ready(asked));
  const auto l = list();
  EXPECT_EQ(l.at(0), "又快又好");
  EXPECT_NE(std::ranges::find(l, shown[0]), l.end());
  zh->key({' ', 0, false});
  EXPECT_EQ(zh->takeCommit(), "又快又好");
  EXPECT_TRUE(rime->learned.empty());  // Rime has no pieces that spell it
}

// Space before the corrected list comes commits the list shown, and the correction never shows after it.
TEST_F(ChineseFixTest, SpaceBeforeTheCorrectionCommitsWhatIsShown) {
  startFixing(300ms);
  const int before = readyCount();
  type("youkuaiyoouhao");
  ASSERT_TRUE(ready(before + 1));
  const auto shown = list();
  list();  // corrections asked, their list 0.3 s away
  zh->key({' ', 0, false});
  EXPECT_EQ(zh->takeCommit(), shown.at(0));
  std::this_thread::sleep_for(400ms);
  const auto after = list();
  EXPECT_EQ(std::ranges::find(after, "又快又好"), after.end());
}

TEST_F(ChineseTest, TraditionalAndNextWords) {
  zh->setAlternate(true);
  typeAndWait("woaini");
  EXPECT_EQ(list().at(0), "我愛你");
  zh->selectAt(0);
  EXPECT_EQ(zh->takeCommit(), "我愛你");
  EXPECT_EQ(rime->learned, (std::vector<std::string>{"我愛你"}));
  // Nothing typed: the next words, in 繁 too, and picking one commits it.
  const int before = readyCount();
  zh->setContext("今天天氣很", "", false);
  ASSERT_TRUE(ready(before));
  const auto next = list();
  ASSERT_FALSE(next.empty());
  EXPECT_NE(std::ranges::find(next, "好"), next.end());
  zh->selectAt(int(std::ranges::find(next, "好") - next.begin()));
  EXPECT_EQ(zh->takeCommit(), "好");
}

// The PCs' box (#495): no next words, so a commit closes it at once.
TEST_F(ChineseTest, WithoutNextWordsACommitEmptiesTheList) {
  start(50ms, {}, false);
  typeAndWait("woaini");
  ASSERT_EQ(list().at(0), "我爱你");
  const int before = readyCount();
  zh->key({' ', 0, false});
  EXPECT_EQ(zh->takeCommit(), "我爱你");
  EXPECT_TRUE(list().empty());
  std::this_thread::sleep_for(200ms);
  EXPECT_EQ(readyCount(), before);
  EXPECT_TRUE(list().empty());
}

// Windows' text service asks again while the model's list is still to come (#495).
TEST_F(ChineseTest, UpdatingUntilTheModelsListComes) {
  start(100ms, {}, false);
  typeAndWait("woaini");
  EXPECT_FALSE(zh->updating());
  const int before = readyCount();
  type("w");
  EXPECT_TRUE(zh->updating());
  ASSERT_TRUE(ready(before));
  EXPECT_FALSE(zh->updating());
  zh->clear();  // nothing typed, no next words: nothing to come
  EXPECT_FALSE(zh->updating());
}

TEST_F(ChineseTest, PunctuationCommitsTheModelsFirst) {
  typeAndWait("woaini");
  ASSERT_EQ(list().at(0), "我爱你");
  zh->key({',', 0, false});
  EXPECT_EQ(zh->takeCommit(), "我爱你，");
}
TEST_F(ChineseTest, FlushCommitsTheModelsFirst) {
  typeAndWait("woaini");
  ASSERT_EQ(list().at(0), "我爱你");
  zh->flush();  // Rime's own flush would commit its sentence, 握挨泥
  EXPECT_EQ(zh->takeCommit(), "我爱你");
  EXPECT_EQ(rime->learned, (std::vector<std::string>{"我爱你"}));
  EXPECT_FALSE(zh->composing());
}

// 你好 spells only nihao of nihaoo: the o left commits after it, as Rime's flush leaves it.
TEST_F(ChineseTest, FlushCommitsWhatAPartialCandidateLeaves) {
  typeAndWait("nihaoo");
  ASSERT_EQ(list().at(0), "你好");
  zh->flush();
  EXPECT_EQ(zh->takeCommit(), "你好o");
  EXPECT_FALSE(zh->composing());
}

// Rime's user dictionary puts a word picked before first (沃门 here, learned): it stays ahead of the model's
// favourite of Rime's, 我们, and of the model's own candidates (握挨泥 over 我爱你, #482: a phrase taught once
// comes first). Rime's first that the user never picked is ranked like Rime's others (#369).
TEST_F(ChineseTest, OnlyALearnedRimeFirstStaysAhead) {
  const auto women = [](FakeRime &r) { r.words["women"] = {"沃门", "我们"}, r.words["men"] = {"们"}; };
  start({}, [&](FakeRime &r) { women(r), r.userWords = {"沃门"}; });
  typeAndWait("women");
  auto l = list();
  ASSERT_GE(l.size(), 2u);
  EXPECT_EQ(l[0], "沃门");
  EXPECT_NE(std::ranges::find(l, "我们"), l.end());

  start({}, women);
  typeAndWait("women");
  l = list();
  ASSERT_GE(l.size(), 2u);
  EXPECT_EQ(l[0], "我们");
  EXPECT_NE(std::ranges::find(l, "沃门"), l.end());

  start({}, [](FakeRime &r) { r.userWords = {"握挨泥"}; });
  typeAndWait("woaini");
  l = list();
  ASSERT_GE(l.size(), 2u);
  EXPECT_EQ(l[0], "握挨泥");
  EXPECT_NE(std::ranges::find(l, "我爱你"), l.end());
}

TEST_F(ChineseTest, TeachingTakesRimesLongestPieces) {
  start({}, [](FakeRime &r) { r.words["woai"] = {"我爱"}; });
  typeAndWait("woaini");
  ASSERT_EQ(list().at(0), "我爱你");
  zh->selectAt(0);
  EXPECT_EQ(zh->takeCommit(), "我爱你");
  EXPECT_EQ(rime->picks.size(), 2u);  // 我爱, then 你
  EXPECT_EQ(rime->learned, (std::vector<std::string>{"我爱你"}));
}

// Rime has no piece for what is left (as for a typo the model fixed): the model's text still commits, and
// Rime, part chosen, learns nothing and keeps nothing.
TEST_F(ChineseTest, AFailedTeachStillCommitsTheModelsText) {
  start({}, [](FakeRime &r) { r.words["ni"] = {"泥"}; });
  typeAndWait("woaini");
  ASSERT_EQ(list().at(0), "我爱你");
  zh->selectAt(0);
  EXPECT_EQ(zh->takeCommit(), "我爱你");
  EXPECT_EQ(rime->picks.size(), 2u);  // 我, 爱
  EXPECT_TRUE(rime->learned.empty());
  EXPECT_FALSE(zh->composing());
}

// 发 is 發 or 髮 in 繁: OpenCC's phrases choose by the word, 头发 → 頭髮.
TEST_F(ChineseTest, TraditionalTakesThePhrasesCharacter) {
  zh->setAlternate(true);
  typeAndWait("toufa");
  const auto l = list();
  EXPECT_NE(std::ranges::find(l, "頭髮"), l.end());
  EXPECT_EQ(std::ranges::find(l, "頭發"), l.end());
}

TEST_F(ChineseTest, NoListComesAfterTheEngineStops) {
  start(300ms);
  typeAndWait("nihao");  // the model loaded
  const int before = readyCount();
  zh->clear();
  type("woaini");
  std::this_thread::sleep_for(100ms);  // its list on the way
  zh.reset();
  EXPECT_EQ(readyCount(), before);
}
TEST_F(ChineseTest, APasswordFieldsTextNeverReachesTheModel) {
  zh->setField(Field::Password);
  zh->setContext("中华人民共和", "", false);
  int before = readyCount();
  zh->setField(Field::Text);  // next words, from the context the password field left: none
  ASSERT_TRUE(ready(before));
  auto next = list();
  EXPECT_EQ(std::ranges::find(next, "国"), next.end());
  before = readyCount();
  zh->setContext("中华人民共和", "", false);  // the same text in a text field
  ASSERT_TRUE(ready(before));
  next = list();
  EXPECT_NE(std::ranges::find(next, "国"), next.end());
}
#endif
