// The PCs' 日本語 engine (mozc.cpp) around a stand-in Mozc that answers as Mozc's session does.
#include <sebtype/hosts.h>

#include <gtest/gtest.h>

#include <algorithm>
#include <vector>

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
