// The PCs' 日本語 engine (mozc.cpp) around a stand-in Mozc that answers as Mozc's session does.
#include <sebtype/hosts.h>

#include <gtest/gtest.h>

#include <vector>

#include "mozc_transport.h"

using namespace sebtype;
using mozc::commands::Input;
using mozc::commands::Output;
using mozc::commands::SessionCommand;

namespace sebtype {
namespace {

// Ctrl+Backspace after a commit, as Mozc's Session::RequestUndo and Session::Undo answer it: the key only asks
// for UNDO in its callback, and UNDO deletes the commit (きしゃ → 記者) and gives its reading back.
struct FakeMozc : MozcTransport {
  std::vector<SessionCommand::CommandType> commands;
  bool call(const Input &in, Output &out) override {
    out.set_id(1);
    if (in.type() == Input::SEND_KEY && in.key().special_key() == mozc::commands::KeyEvent::BACKSPACE &&
        in.key().modifier_keys_size() == 1 && in.key().modifier_keys(0) == mozc::commands::KeyEvent::CTRL) {
      out.set_consumed(true);
      out.mutable_callback()->mutable_session_command()->set_type(SessionCommand::UNDO);
    } else if (in.type() == Input::SEND_COMMAND) {
      commands.push_back(in.command().type());
      out.set_consumed(true);
      if (in.command().type() == SessionCommand::UNDO) {
        out.mutable_deletion_range()->set_offset(-2);
        out.mutable_deletion_range()->set_length(2);
        auto *seg = out.mutable_preedit()->add_segment();
        seg->set_value("きしゃ");
        seg->set_value_length(3);
        seg->set_annotation(mozc::commands::Preedit::Segment::UNDERLINE);
        out.mutable_preedit()->set_cursor(3);
      }
    }
    return true;
  }
  void setLearning(bool) override {}
  bool open() const override { return true; }
  bool loading() const override { return false; }
  void reload() override {}
};
FakeMozc *fake = nullptr;

}  // namespace

std::unique_ptr<MozcTransport> makeMozcTransport(const MozcPaths &) {
  auto t = std::make_unique<FakeMozc>();
  fake = t.get();
  return t;
}

}  // namespace sebtype

TEST(MozcTest, CtrlBackspaceUndoesTheCommitAndGivesItsReadingBack) {
  auto mozc = makeMozc({});
  EXPECT_TRUE(mozc->key({0xff08, mod::Ctrl}));
  EXPECT_EQ(fake->commands.back(), SessionCommand::UNDO);
  EXPECT_EQ(mozc->takeEdit().deleteBefore, 2);
  EXPECT_EQ(mozc->preedit().text(), "きしゃ");
  EXPECT_EQ(mozc->takeEdit().deleteBefore, 0);  // once
}
