// SebType core: how the 日本語 engine (mozc.cpp) reaches Mozc: Mozc's session handler in this process
// (mozc_inprocess.cpp), with the serialized commands of Mozc's protocol. MIT, SebType.
#pragma once

#include <sebtype/hosts.h>

#include <memory>

#include "protocol/commands.pb.h"

namespace sebtype {

class MozcTransport {
 public:
  virtual ~MozcTransport() = default;
  // One command and its answer; false when Mozc didn't load or answer.
  virtual bool call(const mozc::commands::Input &in, mozc::commands::Output &out) = 0;
  // The PCs: whether what is typed adds to Mozc's history (it is still suggested), without touching its files.
  virtual void setLearning(bool learning) = 0;
};

std::unique_ptr<MozcTransport> makeMozcTransport(const MozcPaths &paths);

}  // namespace sebtype
