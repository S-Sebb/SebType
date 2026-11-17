// SebType core: Mozc's session handler in this process (mozc_transport.h, #220), through the C interface of a
// Mozc built into a library (sebtype_mozc.h): the same serialized commands the IPC carries, without the
// server. MIT, SebType.
#include <atomic>
#include <chrono>
#include <cstddef>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <thread>
#include <vector>

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
// frees an idle Mozc); the PCs reload one whose files the Configurator changed. With paths.preload it loads,
// and reloads, in its own thread (#312).
class InProcess final : public MozcTransport {
 public:
  explicit InProcess(const MozcPaths &paths)
      : preload_(paths.preload), profile_(paths.profileDir), data_(paths.dataFile), offset_(paths.dataOffset),
        length_(paths.dataLength) {
    if (preload_.empty()) {
      load();
    } else {
      loading_ = true;
      loader_ = std::thread([this] { loadInBackground(); });
    }
  }
  ~InProcess() override {
    if (loader_.joinable()) loader_.join();
    if (open_) sebtype_mozc_close();
  }

  bool loading() const override { return loading_; }
  bool open() const override { return !loading_ && open_; }

  // A reload asked for while Mozc loads is done by the loading thread before it says it is done: no key goes
  // to the instance it replaces, and no one waits for the load.
  void reload() override {
    {
      std::lock_guard<std::mutex> hold(state_);
      if (loading_) {
        reload_ = true;
        return;
      }
      loading_ = !preload_.empty();
    }
    if (preload_.empty()) return load();
    if (loader_.joinable()) loader_.join();  // done: loading_ was false
    loader_ = std::thread([this] { loadInBackground(); });
  }

  bool call(const mozc::commands::Input &in, mozc::commands::Output &out) override {
    if (!open()) return false;
    if (learning_ && !learningSet_) sebtype_mozc_set_learning(*learning_);
    learningSet_ = true;
    if (!eval(in, out)) return false;
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

  // Applied before the next call, which is when it matters: Mozc may still be loading now.
  void setLearning(bool learning) override {
    learning_ = learning;
    learningSet_ = false;
  }

 private:
  // Opens Mozc, or opens it again: it saves and reads its files again.
  void load() {
    if (open_) sebtype_mozc_close();
    open_ = sebtype_mozc_open(profile_.c_str(), data_.c_str(), offset_, length_) != 0;
    learningSet_ = false;  // the new instance's
  }

  // Reads the DLL through first: see MozcPaths::preload.
  void loadInBackground() {
    {
      std::ifstream f(std::filesystem::u8path(preload_), std::ios::binary);
      std::vector<char> buf(1 << 20);
      while (f.read(buf.data(), buf.size())) {}
    }
    for (;;) {
      load();
      std::lock_guard<std::mutex> hold(state_);
      if (!std::exchange(reload_, false)) {
        loading_ = false;
        return;
      }
    }
  }

  const std::string preload_, profile_, data_;
  const int64_t offset_, length_;
  std::mutex state_;  // loading_ and reload_ between the loading thread and reload()
  std::atomic<bool> open_{false}, loading_{false};
  bool reload_ = false;
  std::thread loader_;
  std::optional<bool> learning_;
  std::atomic<bool> learningSet_{false};
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
