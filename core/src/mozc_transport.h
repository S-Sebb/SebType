// SebType core: how the 日本語 engine (mozc.cpp) reaches Mozc. The PCs talk to mozc_server over Mozc's IPC
// (mozc_ipc.cpp); the phone calls Mozc's session handler in this process (mozc_inprocess.cpp). The commands
// are the same protocol either way. MIT, SebType.
#pragma once

#include <sebtype/hosts.h>

#include <memory>

#include "protocol/commands.pb.h"

namespace sebtype {

class MozcTransport {
 public:
  virtual ~MozcTransport() = default;
  // One command and its answer; false when Mozc couldn't be reached.
  virtual bool call(const mozc::commands::Input &in, mozc::commands::Output &out) = 0;
};

std::unique_ptr<MozcTransport> makeMozcTransport(const MozcPaths &paths);

}  // namespace sebtype
