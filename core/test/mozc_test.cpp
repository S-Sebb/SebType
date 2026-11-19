// The PCs' 日本語 engine (mozc.cpp) around a stand-in Mozc that answers as Mozc's session does.
#include <sebtype/hosts.h>

#include <gtest/gtest.h>

#include <algorithm>
#include <vector>

#include "mozc_learned.h"
#include "mozc_transport.h"

using namespace sebtype;
using mozc::commands::Input;
using mozc::commands::Output;
using mozc::commands::SessionCommand;

namespace sebtype {
namespace {

// As Mozc's session answers: Enter commits 記者, Ctrl+Backspace only asks for UNDO in its callback (Session::
// RequestUndo), and UNDO deletes the commit and converts it again (Session::Undo).
struct FakeMozc : MozcTransport {
  std::vector<SessionCommand::CommandType> commands;
  bool call(const Input &in, Output &out) override {
    out.set_id(1);
    out.set_consumed(true);
    if (in.type() == Input::SEND_KEY && in.key().special_key() == mozc::commands::KeyEvent::ENTER) {
      out.mutable_result()->set_value("記者");
    } else if (in.type() == Input::SEND_KEY && in.key().special_key() == mozc::commands::KeyEvent::BACKSPACE) {
      out.mutable_callback()->mutable_session_command()->set_type(SessionCommand::UNDO);
    } else if (in.type() == Input::SEND_COMMAND) {
      commands.push_back(in.command().type());
      if (in.command().type() == SessionCommand::UNDO) {
        out.mutable_deletion_range()->set_offset(-2);
        out.mutable_deletion_range()->set_length(2);
        auto *seg = out.mutable_preedit()->add_segment();
        seg->set_value("記者");
        seg->set_value_length(2);
        seg->set_annotation(mozc::commands::Preedit::Segment::HIGHLIGHT);
        out.mutable_preedit()->set_cursor(2);
      }
    }
    return true;
  }
  void setLearning(bool) override {}
  bool open() const override { return true; }
  bool loading() const override { return false; }
  void reload() override {}
  void forget() override {}
  void forgetRecord() override {}
  std::string forgetError() const override { return {}; }
  int undos() const { return static_cast<int>(std::count(commands.begin(), commands.end(), SessionCommand::UNDO)); }
};
FakeMozc *fake = nullptr;

}  // namespace

std::unique_ptr<MozcTransport> makeMozcTransport(const MozcPaths &) {
  auto t = std::make_unique<FakeMozc>();
  fake = t.get();
  return t;
}

}  // namespace sebtype

namespace {
constexpr Key Return{0xff0d}, CtrlBackspace{0xff08, mod::Ctrl};
}

TEST(MozcTest, CtrlBackspaceDeletesTheCommitJustBeforeTheCaretAndConvertsItAgain) {
  auto mozc = makeMozc({});
  mozc->key(Return);
  EXPECT_EQ(mozc->takeCommit(), "記者");
  mozc->setContext("今日の記者");
  EXPECT_TRUE(mozc->key(CtrlBackspace));
  EXPECT_EQ(fake->undos(), 1);
  EXPECT_EQ(mozc->takeEdit().deleteBefore, 2);
  EXPECT_EQ(mozc->preedit().text(), "記者");
  EXPECT_EQ(mozc->takeEdit().deleteBefore, 0);  // once
  mozc->setContext("今日の");  // only the last commit
  mozc->key(CtrlBackspace);
  EXPECT_EQ(fake->undos(), 1);
}

// Mozc keeps its undo after focus moves; the commit it would delete is not in the new field (#376).
TEST(MozcTest, CtrlBackspaceUndoesNothingWhereTheCommitIsNotBeforeTheCaret) {
  auto mozc = makeMozc({});
  mozc->key(Return);
  mozc->clear();  // focus moved to another field
  mozc->setContext("記者");
  mozc->key(CtrlBackspace);
  mozc->key(Return);
  mozc->setContext("記者abcd");  // the caret moved
  mozc->key(CtrlBackspace);
  mozc->setContext("記者", {}, true);  // text selected
  mozc->key(CtrlBackspace);
  mozc->key(CtrlBackspace);  // an app that can't say, or delete it
  EXPECT_EQ(fake->undos(), 0);
  EXPECT_EQ(mozc->takeEdit().deleteBefore, 0);
  EXPECT_EQ(mozc->preedit().text(), "");
}

// The learned conversions' record the sync carries (#409). Made-up readings and picks only.
namespace learned = sebtype::learned;
using learned::Other;
using P = learned::Pick;
// Times as seconds after T, a day in 2027; now is T + 2000 unless a test says otherwise, so the picks here before
// T + 1744 replay at their own time (kReplayHeadroom).
constexpr int64_t T = 1'800'000'000, Now = T + 2000;

TEST(MozcLearnedTest, ARecordReadsBackAsWrittenAndAnotherVersionReadsAsEmpty) {
  learned::Record r;
  learned::add(r, "きしゃ", "帰社", T + 100);
  learned::add(r, "きしゃ", "帰社", T + 90);  // the later time stays
  learned::add(r, "かんじ", "幹事", T + 50);
  const std::string text = learned::format(r);
  EXPECT_EQ(text, std::string(learned::kHeader) + "かんじ\t幹事\t1800000050\nきしゃ\t帰社\t1800000100\n");
  EXPECT_EQ(learned::parse(text), r);
  EXPECT_TRUE(learned::parse("# SebType mozc_learned 2\nきしゃ\t帰社\t1800000100\n").empty());
  // A line cut short, or not reading<TAB>written<TAB>time, is left out.
  EXPECT_EQ(learned::parse(std::string(learned::kHeader) + "a\tb\tx\n\tb\t1800000001\na\t\t1800000001\n"
                                                           "a\tb\t1800000001\t2\nかんじ\t幹事\t1800000050\nきし"),
            (learned::Record{{{"かんじ", "幹事"}, T + 50}}));
}

// A time no clock gave is left out, before 2020 or more than a day ahead: Mozc keeps times unsigned, so 5,000
// picks at 1 replayed a second apart would have ranked in 2106 (#415 review).
TEST(MozcLearnedTest, ImpossibleTimesAreLeftOut) {
  const std::string h(learned::kHeader);
  EXPECT_EQ(learned::accept(h + "あ\t亜\t1\nい\t以\t-5\nう\t宇\t1577836799\nえ\t江\t1577836800\nお\t尾\t1800086400\n"
                                "か\t加\t1800086401\n",
                            T),
            (learned::Record{{{"え", "江"}, learned::kEarliest}, {{"お", "尾"}, T + learned::kAhead}}));
  // Spaced back past the earliest time, the picks move forward together, keeping their order in conversion and
  // prediction: 1 and 3 characters a second apart at the earliest time (#415 review).
  const learned::Record early{{{"よみ", "読"}, learned::kEarliest}, {{"よみ", "読みと"}, learned::kEarliest + 1}};
  EXPECT_EQ(learned::toLearn({}, 0, {{early, {}}}, T),
            (std::vector<P>{{"よみ", "読", learned::kEarliest}, {"よみ", "読みと", learned::kEarliest + 3}}));
}

// B's clock is 3 days ahead: its pick isn't taken in yet, and isn't kept as learned, so it comes in once this
// clock catches up. This device's own pick from a clock ahead stays in its record, learned from it only then
// (#415 review).
TEST(MozcLearnedTest, APickFromAClockAheadComesInOnceItIsPossible) {
  constexpr int64_t later = 3 * 24 * 60 * 60;
  const std::string b = std::string(learned::kHeader) + "よみ\tX\t1800259200\n";  // T + 3 days
  const learned::Record taken = learned::accept(b, T);
  EXPECT_TRUE(taken.empty());
  const std::string applied = learned::format(taken);  // kept as learned (mozc_inprocess.cpp)
  EXPECT_EQ(learned::toLearn({}, 0, {{learned::accept(b, T + later), learned::accept(applied, T + later)}}, T + later + learned::kReplayHeadroom),
            (std::vector<P>{{"よみ", "X", T + later}}));
  const learned::Record own = learned::parse(b);
  EXPECT_EQ(learned::parse(learned::format(own)), own);  // made whole again as Mozc starts (learnOthers): kept
  const learned::Record c{{{"よみ", "Y"}, T - 10}};
  EXPECT_EQ(learned::toLearn(own, 0, {{c, {}}}, T + learned::kReplayHeadroom), (std::vector<P>{{"よみ", "Y", T - 10}}));
  EXPECT_EQ(learned::toLearn(own, 0, {{c, {}}}, T + later + learned::kReplayHeadroom),
            (std::vector<P>{{"よみ", "Y", T - 10}, {"よみ", "X", T + later}}));
}

TEST(MozcLearnedTest, ARecordKeepsOnlyTheMostRecentPicks) {
  learned::Record r;
  for (int i = 0; i < static_cast<int>(learned::kMost) + 10; ++i) learned::add(r, "よみ" + std::to_string(i), "読", T + i);
  const learned::Record kept = learned::parse(learned::format(r));
  EXPECT_EQ(kept.size(), learned::kMost);
  EXPECT_FALSE(kept.contains({"よみ9", "読"}));
  EXPECT_TRUE(kept.contains({"よみ10", "読"}));
}

// Two devices convert the same reading differently: the later pick comes first on both, the other stays learned
// below it; at the same second, the written form decides, the same way on both.
TEST(MozcLearnedTest, TheSameReadingPickedDifferentlyOnTwoDevicesEndsTheSameOnBoth) {
  const learned::Record pc{{{"きしゃ", "帰社"}, T + 200}, {{"かんじ", "幹事"}, T + 10}};
  const learned::Record phone{{{"きしゃ", "汽車"}, T + 100}, {{"せいか", "聖火"}, T + 20}};
  // On the PC, the phone's picks: that reading's picks oldest first, the PC's own later one last.
  EXPECT_EQ(learned::toLearn(pc, 0, {{phone, {}}}, Now),
            (std::vector<P>{{"せいか", "聖火", T + 20}, {"きしゃ", "汽車", T + 100}, {"きしゃ", "帰社", T + 200}}));
  // On the phone, the PC's: the same order for きしゃ.
  EXPECT_EQ(learned::toLearn(phone, 0, {{pc, {}}}, Now),
            (std::vector<P>{{"かんじ", "幹事", T + 10}, {"きしゃ", "汽車", T + 100}, {"きしゃ", "帰社", T + 200}}));
  // At the same second, Mozc learns them a second apart, the earlier one a second back; one from a clock ahead,
  // at most now.
  const learned::Record a{{{"きしゃ", "帰社"}, T + 300}}, b{{{"きしゃ", "記者"}, T + 300}};
  EXPECT_EQ(learned::toLearn(a, 0, {{b, {}}}, Now),
            (std::vector<P>{{"きしゃ", "帰社", T + 299}, {"きしゃ", "記者", T + 300}}));
  EXPECT_EQ(learned::toLearn(b, 0, {{a, {}}}, Now),
            (std::vector<P>{{"きしゃ", "帰社", T + 299}, {"きしゃ", "記者", T + 300}}));
  EXPECT_EQ(learned::toLearn({}, 0, {{a, {}}}, T + 250 + learned::kReplayHeadroom), (std::vector<P>{{"きしゃ", "帰社", T + 250}}));
}

// The later pick of a reading comes first in Mozc's prediction too, which scores an entry by its time less the
// characters of its written form (UserHistoryPredictor::GetScore): a longer one picked a second later would have
// lost there (#415 review).
TEST(MozcLearnedTest, TheLaterPickComesFirstInPredictionToo) {
  const learned::Record a{{{"しんぶん", "新聞"}, T + 299}}, b{{{"しんぶん", "しんぶん"}, T + 300}},
      c{{{"しんぶん", "新聞"}, T + 299}, {{"しんぶん", "しんぶん"}, T + 300}, {{"しんぶん", "新聞紙"}, T + 301}};
  // Each character here is 3 bytes of UTF-8.
  const auto score = [](const P &p) { return p.time - static_cast<int64_t>(p.value.size() / 3); };
  for (const auto &picks : {learned::toLearn(a, 0, {{b, {}}}, Now), learned::toLearn({}, 0, {{c, {}}}, Now)}) {
    for (size_t i = 1; i < picks.size(); ++i) {
      EXPECT_LT(picks[i - 1].time, picks[i].time);      // conversion: by time
      EXPECT_LT(score(picks[i - 1]), score(picks[i]));  // prediction
    }
  }
  EXPECT_EQ(learned::toLearn(a, 0, {{b, {}}}, Now),
            (std::vector<P>{{"しんぶん", "新聞", T + 297}, {"しんぶん", "しんぶん", T + 300}}));
  // A pick replayed as late as it can be still scores below a longer one picked here a second after it, or even
  // in the same second as now, of the longest value Mozc keeps (#415 review).
  const P replayed = learned::toLearn({}, 0, {{{{{"しんぶん", "新聞"}, Now}}, {}}}, Now)[0];
  EXPECT_LT(score(replayed), score({"しんぶん", "しんぶん", Now + 1}));
  EXPECT_LT(score(replayed), Now - 256);
}

// Only picks newer than the copy last learned come in; what was learned before, or forgotten since (its record
// kept as learned), doesn't.
TEST(MozcLearnedTest, OnlyNewPicksAreLearned) {
  const learned::Record before{{{"かんじ", "幹事"}, T + 10}};
  learned::Record now = before;
  EXPECT_TRUE(learned::toLearn({}, 0, {{now, before}}, Now).empty());
  learned::add(now, "かんじ", "幹事", T + 30);  // picked again
  learned::add(now, "せいか", "聖火", T + 20);
  EXPECT_EQ(learned::toLearn({}, 0, {{now, before}}, Now),
            (std::vector<P>{{"せいか", "聖火", T + 20}, {"かんじ", "幹事", T + 30}}));
}

// A device that changed nothing since it was learned still counts: A learned C's Y at 300, then B's record brings
// Y at 100 and X at 200, and Y stays first (#415 review).
TEST(MozcLearnedTest, EveryDevicesRecordSettlesWhichPickWins) {
  const learned::Record c{{{"よみ", "Y"}, T + 300}}, b{{{"よみ", "Y"}, T + 100}, {{"よみ", "X"}, T + 200}};
  EXPECT_EQ(learned::toLearn({}, 0, {{c, c}, {b, {}}}, Now),
            (std::vector<P>{{"よみ", "X", T + 200}, {"よみ", "Y", T + 300}}));
}

// After Forget, another device's earlier pick X stays forgotten when it later picks Y for the same reading;
// picked again after the Forget, X comes back (Decisions #2, 2026-11-19).
TEST(MozcLearnedTest, ForgottenPicksStayForgottenUntilPickedAgain) {
  const learned::Record before{{{"よみ", "X"}, T + 400}};
  const int64_t seen = learned::latest(before);  // what Forget kept for that device
  learned::Record now = before;
  learned::add(now, "よみ", "Y", T + 600);
  EXPECT_EQ(learned::toLearn({}, T + 500, {{now, before, seen}}, Now), (std::vector<P>{{"よみ", "Y", T + 600}}));
  learned::Record again = now;
  learned::add(again, "よみ", "X", T + 700);
  EXPECT_EQ(learned::toLearn({}, T + 500, {{again, now, seen}}, Now),
            (std::vector<P>{{"よみ", "Y", T + 600}, {"よみ", "X", T + 700}}));
  // This device's own picks from before the Forget are gone from its record; one after it counts.
  EXPECT_EQ(learned::toLearn({{{"よみ", "Z"}, T + 450}, {{"よみ", "W"}, T + 800}}, T + 500, {{now, before, seen}}, Now),
            (std::vector<P>{{"よみ", "Y", T + 600}, {"よみ", "W", T + 800}}));
}

// A forgets at T + 500 by its clock. B's clock is a minute off: its pick X from 30 s before the Forget and its pick
// Y from 10 s after carry B's times. Forget kept B's latest pick by B's own clock, so X stays forgotten and Y
// counts, whichever way B's clock is off (#415 review).
TEST(MozcLearnedTest, ForgetHoldsWhateverAnotherDevicesClockSays) {
  for (const int64_t off : {60, -60}) {
    const learned::Record before{{{"よみ", "X"}, T + 470 + off}};
    learned::Record after = before;
    learned::add(after, "よみ", "Y", T + 510 + off);
    EXPECT_EQ(learned::toLearn({}, T + 500, {{after, before, learned::latest(before)}}, Now),
              (std::vector<P>{{"よみ", "Y", T + 510 + off}}))
        << off;
  }
  // A device with nothing kept at the Forget: all of its record counts.
  const learned::Record c{{{"よみ", "Z"}, T + 400}};
  EXPECT_EQ(learned::toLearn({}, T + 500, {{c, {}}}, Now), (std::vector<P>{{"よみ", "Z", T + 400}}));
}

TEST(MozcLearnedTest, WhenJapaneseWasForgottenReadsBackAsWritten) {
  const learned::Forgotten f{T + 500, {{"phone", T + 530}, {"laptop", T + 440}}};
  EXPECT_EQ(learned::format(f), "1800000500\nlaptop\t1800000440\nphone\t1800000530\n");
  EXPECT_EQ(learned::parseForgotten(learned::format(f)), f);
  EXPECT_EQ(learned::parseForgotten(""), learned::Forgotten{});
  EXPECT_EQ(learned::parseForgotten("1800000500"), (learned::Forgotten{T + 500, {}}));
}

// Picks kReplayHeadroom before now or later (here at T + 1000 and later) are learned a second apart counting back
// from then, never closer to now: a real pick made after them still ranks above them (#415 review).
TEST(MozcLearnedTest, NoPickIsLearnedCloseToNow) {
  const int64_t now = T + 1000 + learned::kReplayHeadroom;
  const learned::Record r{{{"よみ", "A"}, T + 1000}, {{"よみ", "B"}, T + 1005}, {{"よみ", "C"}, T + 2000}};
  EXPECT_EQ(learned::toLearn({}, 0, {{r, {}}}, now),
            (std::vector<P>{{"よみ", "A", T + 998}, {"よみ", "B", T + 999}, {"よみ", "C", T + 1000}}));
  const learned::Record tie{{{"よみ", "A"}, T + 1000}, {{"よみ", "B"}, T + 1000}};
  EXPECT_EQ(learned::toLearn({}, 0, {{tie, {}}}, now),
            (std::vector<P>{{"よみ", "A", T + 999}, {"よみ", "B", T + 1000}}));
}

// This device's record never passes kMost lines: a pick appends until then, and past it the record is rewritten
// cut back to kKeep. Another device's record is taken in up to kMost picks, and not at all past kMaxBytes.
TEST(MozcLearnedTest, RecordsStayWithinTheCap) {
  const int64_t now = T + 100000;
  learned::Record full;
  for (int i = 0; i < static_cast<int>(learned::kMost); ++i) learned::add(full, "よみ" + std::to_string(i), "読", T + i);
  const std::string text = learned::format(full);
  const learned::Record pick{{{"きしゃ", "帰社"}, T + 99999}};
  const learned::Recorded grown = learned::record(text, pick);
  EXPECT_TRUE(grown.whole);
  const learned::Record kept = learned::parse(grown.text);
  EXPECT_EQ(kept.size(), learned::kKeep);
  EXPECT_TRUE(kept.contains({"きしゃ", "帰社"}));
  EXPECT_EQ(std::count(grown.text.begin(), grown.text.end(), '\n'), static_cast<long>(learned::kKeep) + 1);
  learned::Record less = full;
  less.erase({"よみ0", "読"});
  const learned::Recorded appended = learned::record(learned::format(less), pick);
  EXPECT_FALSE(appended.whole);
  EXPECT_EQ(appended.text, "きしゃ\t帰社\t1800099999\n");
  EXPECT_TRUE(learned::record("", pick).whole);  // a new record

  learned::Record over = full;
  for (int i = 0; i < 10; ++i) learned::add(over, "かな" + std::to_string(i), "仮", T + 90000 + i);
  const learned::Record accepted = learned::accept(learned::format(over, learned::kMost + 10), now);
  EXPECT_EQ(accepted.size(), learned::kMost);
  EXPECT_TRUE(accepted.contains({"かな9", "仮"}));
  EXPECT_FALSE(accepted.contains({"よみ0", "読"}));
  EXPECT_TRUE(learned::accept(std::string(learned::kHeader) + std::string(learned::kMaxBytes, 'x') + "\n", now).empty());
}
