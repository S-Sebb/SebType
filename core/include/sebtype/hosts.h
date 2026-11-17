// SebType core: the engines it hosts. MIT, SebType.
#pragma once

#include <sebtype/engine.h>

#include <chrono>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <string_view>

namespace sebtype {

// 中文: librime with SebType's Chinese data in userDir (rime-ice's schema, 白霜's dictionary).
struct RimePaths {
  std::string sharedDir;  // the system's rime-data, for files the user folder lacks
  std::string userDir;    // learned words, SebType's data and the *.custom.yaml the Configurator writes
  std::string logDir;     // Rime's log files; empty: stderr only
  // The phone's data comes compiled (Decisions #2, #45): Rime starts without a check of its files and
  // deploys only when the frontend asks (deploy()).
  bool prebuilt = false;
  std::string schema;  // selected in each new session; empty: Rime's first
};
std::unique_ptr<Engine> makeRime(const RimePaths &paths);

// 日本語: Mozc, which keeps the dictionary, learned words and settings in profileDir. It runs in this process
// (#220, #233), from SebType's build of engines/mozc: libmozc.so on the phone, libsebtype-mozc.so in the
// Fcitx5 add-on, sebtype-mozc.dll in sebtype-server.exe. One engine per process; makeMozc again after the
// last one went (Core::stop) reads the profile's files again.
struct MozcPaths {
  std::string profileDir;  // Mozc's profile: ~/.mozc if it exists, else ~/.config/mozc on Linux
  // Rime's user folder: its default.custom.yaml's menu/page_size (setup's 6, the Configurator's setting) is
  // 日本語's candidates per page too (Decisions #2, "6 on both"); read again at each deploy.
  std::string rimeUserDir;
  // The phone: Mozc's dictionary, a region of a file (the APK's uncompressed resource; length 0: all of it;
  // empty on the PCs: the one built into the library), and Mozc set up for a touch keyboard.
  std::string dataFile;
  int64_t dataOffset = 0, dataLength = 0;
  bool touch = false;
};
std::unique_ptr<Engine> makeMozc(const MozcPaths &paths);
// The phone's user dictionaries: a file in any format Mozc imports (Mozc, MS-IME, ATOK, Kotoeri), as a
// serialized mozc.user_dictionary.UserDictionary; entries Mozc can't read are skipped.
std::string importMozcUserDictionary(std::string_view text);

// English on the phone (#244): pristine AOSP LatinIME's decoder (engines/latinime) finds the words near the
// letters typed, SebType's model (engines/sebtype-lm) ranks them, decides what a space corrects and predicts the
// next words. The PCs keep plain English (their factories return no English engine).
struct EnglishPaths {
  // The main dictionary (data/en-dict/en_US.dict), a region of a file (length 0: all of it).
  std::string dictionary;
  int64_t dictionaryOffset = 0, dictionaryLength = 0;
  std::string model;    // SebType's model (engines/sebtype-lm/english.gguf); loaded on the first letter typed
  std::string userDir;  // learned words: AOSP's user-history dictionary in userDir/en_history
  std::chrono::milliseconds rankDelay{0};  // tests: each ranking takes this much longer, as on a slow phone
};
// READY runs on the engine's worker thread when the model has ranked the word being typed or found next words
// for the text so far: the frontend posts it to its own thread and reads candidates() there.
std::unique_ptr<Engine> makeEnglish(const EnglishPaths &paths, std::function<void()> ready);

}  // namespace sebtype
