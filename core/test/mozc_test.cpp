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

TEST(MozcLearnedTest, ARecordReadsBackAsWrittenAndAnotherVersionReadsAsEmpty) {
  learned::Record r;
  learned::add(r, "きしゃ", "帰社", 100);
  learned::add(r, "きしゃ", "帰社", 90);  // the later time stays
  learned::add(r, "かんじ", "幹事", 50);
  const std::string text = learned::format(r);
  EXPECT_EQ(text, std::string(learned::kHeader) + "かんじ\t幹事\t50\nきしゃ\t帰社\t100\n");
  EXPECT_EQ(learned::parse(text), r);
  EXPECT_TRUE(learned::parse("# SebType mozc_learned 2\nきしゃ\t帰社\t100\n").empty());
  // A line cut short, or not reading<TAB>written<TAB>time, is left out.
  EXPECT_EQ(learned::parse(std::string(learned::kHeader) + "a\tb\tx\n\tb\t1\na\t\t1\na\tb\t1\t2\nかんじ\t幹事\t50\nきし"),
            (learned::Record{{{"かんじ", "幹事"}, 50}}));
}

TEST(MozcLearnedTest, ARecordKeepsOnlyTheMostRecentPicks) {
  learned::Record r;
  for (int i = 0; i < static_cast<int>(learned::kMost) + 10; ++i) learned::add(r, "よみ" + std::to_string(i), "読", i);
  const learned::Record kept = learned::parse(learned::format(r));
  EXPECT_EQ(kept.size(), learned::kMost);
  EXPECT_FALSE(kept.contains({"よみ9", "読"}));
  EXPECT_TRUE(kept.contains({"よみ10", "読"}));
}

// Two devices convert the same reading differently: the later pick comes first on both, the other stays learned
// below it; at the same second, the written form decides, the same way on both.
TEST(MozcLearnedTest, TheSameReadingPickedDifferentlyOnTwoDevicesEndsTheSameOnBoth) {
  const learned::Record pc{{{"きしゃ", "帰社"}, 200}, {{"かんじ", "幹事"}, 10}};
  const learned::Record phone{{{"きしゃ", "汽車"}, 100}, {{"せいか", "聖火"}, 20}};
  using P = learned::Pick;
  // On the PC, the phone's picks: that reading's picks oldest first, the PC's own later one last.
  EXPECT_EQ(learned::toLearn(pc, {{phone, {}}}, 1000),
            (std::vector<P>{{"せいか", "聖火", 20}, {"きしゃ", "汽車", 100}, {"きしゃ", "帰社", 200}}));
  // On the phone, the PC's: the same order for きしゃ.
  EXPECT_EQ(learned::toLearn(phone, {{pc, {}}}, 1000),
            (std::vector<P>{{"かんじ", "幹事", 10}, {"きしゃ", "汽車", 100}, {"きしゃ", "帰社", 200}}));
  // At the same second, Mozc learns them a second apart; one from a clock ahead, at most now.
  const learned::Record a{{{"きしゃ", "帰社"}, 300}}, b{{{"きしゃ", "記者"}, 300}};
  EXPECT_EQ(learned::toLearn(a, {{b, {}}}, 1000), (std::vector<P>{{"きしゃ", "帰社", 300}, {"きしゃ", "記者", 301}}));
  EXPECT_EQ(learned::toLearn(b, {{a, {}}}, 1000), (std::vector<P>{{"きしゃ", "帰社", 300}, {"きしゃ", "記者", 301}}));
  EXPECT_EQ(learned::toLearn({}, {{a, {}}}, 250), (std::vector<P>{{"きしゃ", "帰社", 250}}));
}

// Only picks newer than the copy last learned come in; what was learned before, or forgotten since (its record
// kept as learned), doesn't.
TEST(MozcLearnedTest, OnlyNewPicksAreLearned) {
  const learned::Record before{{{"かんじ", "幹事"}, 10}};
  learned::Record now = before;
  EXPECT_TRUE(learned::toLearn({}, {{now, before}}, 100).empty());
  learned::add(now, "かんじ", "幹事", 30);  // picked again
  learned::add(now, "せいか", "聖火", 20);
  EXPECT_EQ(learned::toLearn({}, {{now, before}}, 100),
            (std::vector<learned::Pick>{{"せいか", "聖火", 20}, {"かんじ", "幹事", 30}}));
}
