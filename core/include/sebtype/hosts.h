// SebType core: the engines it hosts. MIT, SebType.
#pragma once

#include <sebtype/engine.h>

#include <cstdint>
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

// 日本語: Mozc, which keeps the dictionary, learned words and settings in profileDir. On the PCs it runs in
// its own mozc_server (SebType's build of engines/mozc), over Mozc's IPC; on the phone in this process
// (libmozc.so, built from the same Mozc).
struct MozcPaths {
  std::string server;      // mozc_server, started when none runs
  std::string profileDir;  // Mozc's profile: ~/.config/mozc on Linux
  // Rime's user folder: its default.custom.yaml's menu/page_size (setup's 6, the Configurator's setting) is
  // 日本語's candidates per page too (Decisions #2, "6 on both"); read again at each deploy.
  std::string rimeUserDir;
  // The phone: Mozc's dictionary, a region of a file (the APK's uncompressed resource; length 0: all of it),
  // and Mozc set up for a touch keyboard.
  std::string dataFile;
  int64_t dataOffset = 0, dataLength = 0;
  bool touch = false;
};
std::unique_ptr<Engine> makeMozc(const MozcPaths &paths);
#ifdef __ANDROID__
// The phone's user dictionaries: a file in any format Mozc imports (Mozc, MS-IME, ATOK, Kotoeri), as a
// serialized mozc.user_dictionary.UserDictionary; entries Mozc can't read are skipped.
std::string importMozcUserDictionary(std::string_view text);
#endif

}  // namespace sebtype
