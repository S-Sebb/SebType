// SebType core: the phone's way to Mozc (mozc_transport.h). Mozc's session handler runs in this process, in
// libmozc.so (engines/mozc's android/jni, built by Bazel): its exports take and return serialized commands,
// as its Java client's evalCommand did. MIT, SebType.
#include <dlfcn.h>

#include <cstddef>
#include <cstdint>
#include <cstdlib>

#include "mozc_transport.h"

namespace sebtype {

namespace {

// libmozc.so's exports (mozcjni.cc).
struct Mozc {
  bool (*load)(const char *profileDir, const char *dataFile, int64_t offset, int64_t length);
  void (*unload)();
  size_t (*eval)(const void *in, size_t size, char **out);
  size_t (*importUserDictionary)(const char *text, size_t size, char **out);
  void (*free)(char *bytes);
};

const Mozc *mozc() {
  static const Mozc *m = [] () -> const Mozc * {
    void *lib = dlopen("libmozc.so", RTLD_NOW);
    if (!lib) return nullptr;
    static Mozc fns{
        reinterpret_cast<decltype(Mozc::load)>(dlsym(lib, "SebTypeMozcLoad")),
        reinterpret_cast<decltype(Mozc::unload)>(dlsym(lib, "SebTypeMozcUnload")),
        reinterpret_cast<decltype(Mozc::eval)>(dlsym(lib, "SebTypeMozcEval")),
        reinterpret_cast<decltype(Mozc::importUserDictionary)>(dlsym(lib, "SebTypeMozcImportUserDictionary")),
        reinterpret_cast<decltype(Mozc::free)>(dlsym(lib, "SebTypeMozcFree")),
    };
    return fns.load && fns.unload && fns.eval && fns.importUserDictionary && fns.free ? &fns : nullptr;
  }();
  return m;
}

std::string take(const Mozc &m, char *bytes, size_t size) {
  std::string s(bytes, size);
  m.free(bytes);
  return s;
}

// One session handler for the process: the 日本語 engine's, loaded with it and unloaded when the core stops
// it (the phone frees an idle Mozc).
class InProcess final : public MozcTransport {
 public:
  explicit InProcess(const MozcPaths &paths) {
    const Mozc *m = mozc();
    loaded_ = m && m->load(paths.profileDir.c_str(), paths.dataFile.c_str(), paths.dataOffset, paths.dataLength);
  }
  ~InProcess() override {
    if (loaded_) mozc()->unload();
  }

  bool call(const mozc::commands::Input &in, mozc::commands::Output &out) override {
    if (!loaded_) return false;
    mozc::commands::Command command;
    *command.mutable_input() = in;
    const std::string bytes = command.SerializeAsString();
    char *answer = nullptr;
    const size_t size = mozc()->eval(bytes.data(), bytes.size(), &answer);
    if (!command.ParseFromString(take(*mozc(), answer, size))) return false;
    out = command.output();
    return true;
  }

 private:
  bool loaded_ = false;
};

}  // namespace

std::unique_ptr<MozcTransport> makeMozcTransport(const MozcPaths &paths) {
  return std::make_unique<InProcess>(paths);
}

std::string importMozcUserDictionary(std::string_view text) {
  const Mozc *m = mozc();
  if (!m) return {};
  char *out = nullptr;
  const size_t size = m->importUserDictionary(text.data(), text.size(), &out);
  return take(*m, out, size);
}

}  // namespace sebtype
