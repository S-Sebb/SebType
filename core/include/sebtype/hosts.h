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
  std::string logDir;     // Rime's log files; empty: stderr only
};
std::unique_ptr<Engine> makeRime(const RimePaths &paths);

// 日本語: Mozc, through its own mozc_server (SebType's build of engines/mozc), which keeps the
// dictionary, learned words and settings in profileDir.
struct MozcPaths {
  std::string server;      // mozc_server, started when none runs
  std::string profileDir;  // Mozc's profile: ~/.config/mozc on Linux
  // Rime's user folder: its default.custom.yaml's menu/page_size (setup's 6, the Configurator's setting) is
  // 日本語's candidates per page too (Decisions #2, "6 on both"); read again at each deploy.
  std::string rimeUserDir;
};
std::unique_ptr<Engine> makeMozc(const MozcPaths &paths);

}  // namespace sebtype
