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

// SebType: the phone's entry points to SessionHandler, which SebType's core (core/src/mozc_inprocess.cpp)
// calls in the same process: serialized commands in and out, as the Java client's JNI evalCommand did.

#ifdef __ANDROID__

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
#include "base/system_util.h"
#include "client/user_dictionary/user_dictionary_importer.h"
#include "data_manager/data_manager.h"
#include "engine/engine.h"
#include "protocol/commands.pb.h"
#include "protocol/user_dictionary_storage.pb.h"
#include "session/session_handler.h"

namespace mozc {
namespace jni {
namespace {

// The process's Mozc, loaded by SebTypeMozcLoad.
std::unique_ptr<SessionHandler> g_session_handler;

// A copy the caller frees with SebTypeMozcFree.
size_t Copy(absl::string_view s, char** out) {
  *out = static_cast<char*>(std::malloc(s.size() ? s.size() : 1));
  std::memcpy(*out, s.data(), s.size());
  return s.size();
}

// SebType: a data file length of 0 maps the whole file; otherwise the data set is the region
// [offset, offset + length) of the file, e.g. an uncompressed resource inside the APK.
std::unique_ptr<EngineInterface> CreateMobileEngine(
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

}  // namespace
}  // namespace jni
}  // namespace mozc

extern "C" {

// Loads Mozc with this user profile and data set (an empty path: Mozc's minimal engine). A later call
// replaces the SessionHandler, so the keyboard can reload Mozc with another data file or user profile.
__attribute__((visibility("default"))) bool SebTypeMozcLoad(
    const char* profile_dir, const char* data_file, int64_t offset,
    int64_t length) {
  using mozc::jni::g_session_handler;
  g_session_handler.reset();
  const std::string original_dir = mozc::SystemUtil::GetUserProfileDirectory();
  mozc::SystemUtil::SetUserProfileDirectory(profile_dir);
  std::unique_ptr<mozc::EngineInterface> engine =
      *data_file ? mozc::jni::CreateMobileEngine(data_file, offset, length)
                 : mozc::Engine::CreateEngine();
  DCHECK(engine);
  g_session_handler = std::make_unique<mozc::SessionHandler>(std::move(engine));
  if (!g_session_handler) {
    mozc::SystemUtil::SetUserProfileDirectory(original_dir);
    LOG(DFATAL) << "Failed to create Mozc session handler";
    return false;
  }
  return true;
}

// Frees the engine (its dictionary and caches) until the next load.
__attribute__((visibility("default"))) void SebTypeMozcUnload() {
  mozc::jni::g_session_handler.reset();
}

// Evaluates a serialized mozc.commands.Command and returns it with its output.
__attribute__((visibility("default"))) size_t SebTypeMozcEval(const void* in,
                                                              size_t size,
                                                              char** out) {
  mozc::commands::Command command;
  command.ParseFromArray(in, static_cast<int>(size));
  if (mozc::jni::g_session_handler) {
    mozc::jni::g_session_handler->EvalCommand(&command);
  } else {
    LOG(DFATAL) << "Mozc session handler is not yet initialized";
  }
  return mozc::jni::Copy(command.SerializeAsString(), out);
}

// SebType: parses a user dictionary file the user imported (Mozc, MS-IME, ATOK or Kotoeri text) into a
// serialized UserDictionary, skipping entries it can't read. The phone writes user_dictionary.db with it,
// since Mozc no longer takes user dictionary commands.
__attribute__((visibility("default"))) size_t SebTypeMozcImportUserDictionary(
    const char* text, size_t size, char** out) {
  const std::string input(text, size);
  mozc::user_dictionary::StringTextLineIterator iter(input);
  mozc::user_dictionary::UserDictionary dictionary;
  if (absl::Status status = mozc::user_dictionary::ImportFromTextLineIterator(
          mozc::user_dictionary::IME_AUTO_DETECT, &iter, &dictionary);
      !status.ok()) {
    LOG(WARNING) << "User dictionary import: " << status;
  }
  return mozc::jni::Copy(dictionary.SerializeAsString(), out);
}

__attribute__((visibility("default"))) void SebTypeMozcFree(char* bytes) {
  std::free(bytes);
}

}  // extern "C"

#endif  // __ANDROID__
