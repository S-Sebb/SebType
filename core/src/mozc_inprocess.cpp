// SebType core: Mozc's session handler in this process (mozc_transport.h, #220), through the C interface of a
// Mozc built into a library (sebtype_mozc.h): the same serialized commands the IPC carries, without the
// server. MIT, SebType.
#include <chrono>
#include <cstddef>
#include <string>

#include "mozc_transport.h"
#include "sebtype_mozc.h"

namespace sebtype {

namespace {

using Clock = std::chrono::steady_clock;

// mozc_server's watchdog saved learned words every 180 s; in-process nothing does, so this transport saves
// that often after a commit. The frontend still saves when it stops or hides (Engine::save), and closing
// saves too.
constexpr auto kSaveEvery = std::chrono::seconds(180);

std::string take(char *bytes, size_t size) {
  std::string s(bytes, size);
  sebtype_mozc_free(bytes);
  return s;
}

bool eval(const mozc::commands::Input &in, mozc::commands::Output &out) {
  const std::string request = in.SerializeAsString();
  char *reply = nullptr;
  size_t size = 0;
  if (!sebtype_mozc_eval(request.data(), request.size(), &reply, &size)) return false;
  return out.ParseFromString(take(reply, size));
}

// One engine per process, the 日本語 engine's: loaded with it and closed when the core stops it (the phone
// frees an idle Mozc; the PCs reload one whose files the Configurator changed).
class InProcess final : public MozcTransport {
 public:
  explicit InProcess(const MozcPaths &paths)
      : open_(sebtype_mozc_open(paths.profileDir.c_str(), paths.dataFile.c_str(), paths.dataOffset,
                                paths.dataLength) != 0) {}
  ~InProcess() override {
    if (open_) sebtype_mozc_close();
  }

  bool call(const mozc::commands::Input &in, mozc::commands::Output &out) override {
    if (!open_ || !eval(in, out)) return false;
    if (in.type() == mozc::commands::Input::SYNC_DATA) {
      unsaved_ = false;
      savedAt_ = Clock::now();
    } else if (out.has_result()) {
      unsaved_ = true;
    }
    if (unsaved_ && Clock::now() - savedAt_ >= kSaveEvery) {
      mozc::commands::Input sync;
      sync.set_type(mozc::commands::Input::SYNC_DATA);
      mozc::commands::Output ignored;
      eval(sync, ignored);
      unsaved_ = false;
      savedAt_ = Clock::now();
    }
    return true;
  }

  void setLearning(bool learning) override {
    if (open_) sebtype_mozc_set_learning(learning);
  }

 private:
  bool open_;
  bool unsaved_ = false;
  Clock::time_point savedAt_ = Clock::now();
};

}  // namespace

std::unique_ptr<MozcTransport> makeMozcTransport(const MozcPaths &paths) {
  return std::make_unique<InProcess>(paths);
}

std::string importMozcUserDictionary(std::string_view text) {
  char *out = nullptr;
  size_t size = 0;
  if (!sebtype_mozc_import_user_dictionary(text.data(), text.size(), &out, &size)) return {};
  return take(out, size);
}

}  // namespace sebtype
