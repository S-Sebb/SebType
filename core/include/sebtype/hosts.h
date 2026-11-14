// SebType core: the engines it hosts. MIT, SebType.
#pragma once

#include <sebtype/engine.h>

#include <memory>
#include <string>

namespace sebtype {

// 中文: librime with SebType's Chinese data in userDir (rime-ice's schema, 白霜's dictionary).
struct RimePaths {
  std::string sharedDir;  // the system's rime-data, for files the user folder lacks
  std::string userDir;    // learned words, SebType's data and the *.custom.yaml the Configurator writes
};
std::unique_ptr<Engine> makeRime(const RimePaths &paths);

// 日本語: Mozc, through its own mozc_server (SebType's build of engines/mozc), which keeps the
// dictionary, learned words and settings in profileDir.
struct MozcPaths {
  std::string server;      // mozc_server, started when none runs
  std::string profileDir;  // Mozc's profile: ~/.config/mozc on Linux
};
std::unique_ptr<Engine> makeMozc(const MozcPaths &paths);

}  // namespace sebtype
