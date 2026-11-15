// The core's riskiest paths with stand-in engines: language switching, the Shift tap, 简/繁, あ ⇄ ア,
// paging 6 to a page, and the phone's 🌐, list and fields.
#include <sebtype/core.h>

#include <gtest/gtest.h>

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
  void flush() override { commit += typed, typed.clear(); }
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
    if (on) flush();
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
  Core core{[this](Lang l) {
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
  EXPECT_EQ(core.takeCommit(), "ni");
  EXPECT_EQ(menuLabels(), (std::vector<std::string>{"中文", "English", "-"}));
  core.setSettings(Settings::parse("[Languages]\nOrder=ja\n"));
  EXPECT_EQ(core.language(), Lang::Japanese);  // English went off
  EXPECT_EQ(Settings::parse("[Languages]\nOrder=ja,en,zh\n").serialize(), "[Languages]\nOrder=ja,en,zh\n");
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
