// Copyright 2010-2021, Google Inc.
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     * Redistributions of source code must retain the above copyright
// notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above
// copyright notice, this list of conditions and the following disclaimer
// in the documentation and/or other materials provided with the
// distribution.
//     * Neither the name of Google Inc. nor the names of its
// contributors may be used to endorse or promote products derived from
// this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

// SebType: Mozc as a library with SebType's C interface (core/src/sebtype_mozc.h), which SebType's core
// (core/src/mozc_inprocess.cpp) calls in the same process: serialized commands in and out, as the Java
// client's JNI evalCommand did. The phone's libmozc.so, the Fcitx5 add-on's libsebtype-mozc.so and
// sebtype-server.exe's sebtype-mozc.dll are this file (#220, #233).

#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <utility>

#include "absl/log/check.h"
#include "absl/log/log.h"
#include "absl/status/status.h"
#include "absl/status/statusor.h"
#include "absl/strings/string_view.h"
#include "absl/time/time.h"
#include "base/clock.h"
#include "base/system_util.h"
#include "client/user_dictionary/user_dictionary_importer.h"
#include "config/config_handler.h"
#include "converter/attribute.h"
#include "converter/candidate.h"
#include "converter/converter.h"
#include "converter/segments.h"
#include "data_manager/data_manager.h"
#include "engine/engine.h"
#ifndef __ANDROID__
#include "engine/engine_factory.h"
#endif
#include "protocol/commands.pb.h"
#include "protocol/config.pb.h"
#include "protocol/user_dictionary_storage.pb.h"
#include "request/conversion_request.h"
#include "session/session_handler.h"

namespace mozc {
namespace sebtype {
namespace {

// The process's Mozc, loaded by sebtype_mozc_open, and its engine.
std::unique_ptr<SessionHandler> g_session_handler;
Engine* g_engine = nullptr;

// SebType (#409): the conversions the user picked since sebtype_mozc_take_learned last took them, as
// reading<TAB>written lines. A replay (sebtype_mozc_learn) isn't a pick.
std::string g_learned;

// The time sebtype_mozc_learn gives Mozc's clock.
class PickedAt : public ClockInterface {
 public:
  explicit PickedAt(absl::Time time) : time_(time) {}
  absl::Time GetAbslTime() override { return time_; }
  absl::TimeZone GetTimeZone() override { return absl::LocalTimeZone(); }

 private:
  const absl::Time time_;
};
bool g_replaying = false;

void Learned(absl::string_view key, absl::string_view value) {
  if (g_replaying || key.find_first_of("\t\r\n") != absl::string_view::npos ||
      value.find_first_of("\t\r\n") != absl::string_view::npos) {
    return;
  }
  g_learned.append(key).append("\t").append(value).append("\n");
}

// A copy the caller frees with sebtype_mozc_free.
void Copy(absl::string_view s, char** out, size_t* out_size) {
  *out = static_cast<char*>(std::malloc(s.size() ? s.size() : 1));
  std::memcpy(*out, s.data(), s.size());
  *out_size = s.size();
}

// SebType: a data file length of 0 maps the whole file; otherwise the data set is the region
// [offset, offset + length) of the file, e.g. an uncompressed resource inside the APK.
std::unique_ptr<Engine> CreateMobileEngine(
    const std::string& data_file_path, size_t offset, size_t length) {
  absl::StatusOr<std::unique_ptr<const DataManager>> data_manager =
      length == 0
          ? DataManager::CreateFromFile(data_file_path)
          : DataManager::CreateFromFileRegion(data_file_path, offset, length);
  if (!data_manager.ok()) {
    LOG(ERROR)
        << "Fallback to minimal engine due to data manager creation failure: "
        << data_manager.status();
    return Engine::CreateEngine();
  }
  // NOTE: we need to copy the data version to our local string before calling
  // `Engine::CreateEngine` because, if the engine creation below fails,
  // it deletes `data_manager` and all the references to its data get
  // invalidated. We want to log the data version on failure, so its copy is
  // necessary.
  const std::string data_version =
      std::string((*data_manager)->GetDataVersion());
  auto engine = Engine::CreateEngine(*std::move(data_manager));
  if (!engine.ok()) {
    LOG(ERROR) << "Failed to create a mobile engine: file " << data_file_path
               << ", data version: " << data_version << ": " << engine.status()
               << ": Fallback to minimal engine";
    return Engine::CreateEngine();
  }
  LOG(INFO) << "Successfully created a mobile engine from " << data_file_path
            << ", data version=" << data_version;
  return *std::move(engine);
}

// The PCs' engine: the dictionary built into this library, as mozc_server had it.
std::unique_ptr<Engine> CreateDesktopEngine() {
#ifdef __ANDROID__
  return Engine::CreateEngine();
#else
  absl::StatusOr<std::unique_ptr<Engine>> engine = EngineFactory::Create();
  if (!engine.ok()) {
    LOG(ERROR) << "Failed to create the built-in engine: " << engine.status()
               << ": Fallback to minimal engine";
    return Engine::CreateEngine();
  }
  return *std::move(engine);
#endif
}

}  // namespace
}  // namespace sebtype
}  // namespace mozc

// Exported by sebtype_mozc.map on Linux and Android, by sebtype_mozc.def on Windows.
#ifdef _WIN32
#define SEBTYPE_MOZC_API
#else
#define SEBTYPE_MOZC_API __attribute__((visibility("default")))
#endif

extern "C" {

SEBTYPE_MOZC_API void sebtype_mozc_close();

// Loads Mozc with this user profile and data set (an empty path: the dictionary built in on the PCs,
// Mozc's minimal engine on the phone). A later call replaces the SessionHandler, so the keyboard can reload
// Mozc with another data file or user profile; the PCs reopen it to read the files the Configurator changed.
SEBTYPE_MOZC_API int sebtype_mozc_open(
    const char* profile_dir, const char* data_file, int64_t offset,
    int64_t length) {
  using mozc::sebtype::g_session_handler;
  sebtype_mozc_close();
  const std::string original_dir = mozc::SystemUtil::GetUserProfileDirectory();
  mozc::SystemUtil::SetUserProfileDirectory(profile_dir);
  // The settings (config1.db) are kept per process, not per engine: read them again.
  mozc::config::ConfigHandler::Reload();
  std::unique_ptr<mozc::Engine> engine =
      *data_file ? mozc::sebtype::CreateMobileEngine(data_file, offset, length)
                 : mozc::sebtype::CreateDesktopEngine();
  DCHECK(engine);
  mozc::sebtype::g_engine = engine.get();
  mozc::converter::sebtype_learned = mozc::sebtype::Learned;
  g_session_handler = std::make_unique<mozc::SessionHandler>(std::move(engine));
  if (!g_session_handler) {
    mozc::SystemUtil::SetUserProfileDirectory(original_dir);
    LOG(DFATAL) << "Failed to create Mozc session handler";
    return 0;
  }
  return 1;
}

// Saves learned words and frees the engine, its dictionary and caches, until the next open. Mozc's
// destructors don't save its input history, so this syncs first, as mozc_server did on shutdown.
SEBTYPE_MOZC_API void sebtype_mozc_close() {
  using mozc::sebtype::g_session_handler;
  if (!g_session_handler) return;
  mozc::commands::Command sync;
  sync.mutable_input()->set_type(mozc::commands::Input::SYNC_DATA);
  g_session_handler->EvalCommand(&sync);
  g_session_handler.reset();
  mozc::sebtype::g_engine = nullptr;
}

// Evaluates a serialized mozc.commands.Input and returns its serialized Output.
SEBTYPE_MOZC_API int sebtype_mozc_eval(const char* in,
                                                            size_t in_size,
                                                            char** out,
                                                            size_t* out_size) {
  if (!mozc::sebtype::g_session_handler) return 0;
  mozc::commands::Command command;
  if (!command.mutable_input()->ParseFromArray(in, static_cast<int>(in_size))) {
    return 0;
  }
  if (!mozc::sebtype::g_session_handler->EvalCommand(&command)) return 0;
  mozc::sebtype::Copy(command.output().SerializeAsString(), out, out_size);
  return 1;
}

// SebType (#270): the PCs' learning in a private field. Not learning makes the history read-only (still
// suggested, nothing added) in memory only, so config1.db keeps the user's settings and the Configurator's
// own writes never race it. Learning off in config1.db (NO_HISTORY) stays.
SEBTYPE_MOZC_API void sebtype_mozc_set_learning(int learning) {
  using mozc::config::Config;
  if (!mozc::sebtype::g_session_handler) return;
  Config config = mozc::config::ConfigHandler::GetCopiedConfig();
  const Config::HistoryLearningLevel want =
      learning ? Config::DEFAULT_HISTORY : Config::READ_ONLY;
  if (config.history_learning_level() == Config::NO_HISTORY ||
      config.history_learning_level() == want) {
    return;
  }
  config.set_history_learning_level(want);
  mozc::config::ConfigHandler::SetImposedConfig(std::move(config));
  // GET_CONFIG hands the new config to the sessions (SessionHandler::UpdateSessions).
  mozc::commands::Command get;
  get.mutable_input()->set_type(mozc::commands::Input::GET_CONFIG);
  mozc::sebtype::g_session_handler->EvalCommand(&get);
}

// SebType (#409): the conversions the user picked since the last call, as reading<TAB>written lines.
SEBTYPE_MOZC_API int sebtype_mozc_take_learned(char** out, size_t* out_size) {
  mozc::sebtype::Copy(mozc::sebtype::g_learned, out, out_size);
  mozc::sebtype::g_learned.clear();
  return 1;
}

// SebType (#409): learns a conversion another device's user picked as if it were picked here, into
// segment.db and the history as Mozc learns a pick (Converter::FinishConversion), one segment without the
// words around it, as picked at `time` (seconds since 1970): Mozc ranks what it learned by when. Learning off
// still takes it in: what was learned is used (#374).
SEBTYPE_MOZC_API int sebtype_mozc_learn(const char* key, size_t key_size,
                                        const char* value, size_t value_size,
                                        int64_t time) {
  using mozc::converter::Attribute;
  mozc::Engine* engine = mozc::sebtype::g_engine;
  if (engine == nullptr || key_size == 0 || value_size == 0) return 0;
  engine->Wait();  // the history loads in its own thread, and would replace what this adds
  mozc::config::Config config = mozc::config::ConfigHandler::GetCopiedConfig();
  config.set_history_learning_level(mozc::config::Config::DEFAULT_HISTORY);
  config.set_incognito_mode(false);
  const mozc::ConversionRequest request =
      mozc::ConversionRequestBuilder().SetConfig(config).Build();
  mozc::Segments segments;
  mozc::Segment* segment = segments.add_segment();
  segment->set_key(absl::string_view(key, key_size));
  segment->set_segment_type(mozc::Segment::FIXED_VALUE);
  mozc::converter::Candidate* c = segment->add_candidate();
  c->key = c->content_key = segment->key();
  c->value = c->content_value = std::string(value, value_size);
  c->attributes |= Attribute::RERANKED;  // picked over Mozc's first candidate
  // Mozc's clock is process-wide: the engine's other threads are idle here (Wait above, and typing waits on
  // this call), so only this learning reads it.
  mozc::sebtype::PickedAt clock(absl::FromUnixSeconds(time));
  mozc::Clock::SetClockForUnitTest(&clock);
  mozc::sebtype::g_replaying = true;
  engine->GetConverter()->FinishConversion(request, &segments);
  mozc::sebtype::g_replaying = false;
  mozc::Clock::SetClockForUnitTest(nullptr);
  return 1;
}

// SebType: parses a user dictionary file the user imported (Mozc, MS-IME, ATOK or Kotoeri text) into a
// serialized UserDictionary, skipping entries it can't read. The phone writes user_dictionary.db with it,
// since Mozc no longer takes user dictionary commands.
SEBTYPE_MOZC_API int sebtype_mozc_import_user_dictionary(
    const char* text, size_t size, char** out, size_t* out_size) {
  const std::string input(text, size);
  mozc::user_dictionary::StringTextLineIterator iter(input);
  mozc::user_dictionary::UserDictionary dictionary;
  if (absl::Status status = mozc::user_dictionary::ImportFromTextLineIterator(
          mozc::user_dictionary::IME_AUTO_DETECT, &iter, &dictionary);
      !status.ok()) {
    LOG(WARNING) << "User dictionary import: " << status;
  }
  mozc::sebtype::Copy(dictionary.SerializeAsString(), out, out_size);
  return 1;
}

SEBTYPE_MOZC_API void sebtype_mozc_free(char* bytes) {
  std::free(bytes);
}

}  // extern "C"
