// SebType core: trace sections for the models' work (#320, #264). MIT, SebType.
#pragma once

#ifdef __ANDROID__
#include <android/trace.h>
#endif

namespace sebtype {

// A trace section from here to the end of the scope: in Perfetto traces on Android, where android/perf/perf.sh
// reads the models' times and what each space did; nothing elsewhere.
struct TraceSection {
  explicit TraceSection([[maybe_unused]] const char *name) {
#ifdef __ANDROID__
    ATrace_beginSection(name);
#endif
  }
  ~TraceSection() {
#ifdef __ANDROID__
    ATrace_endSection();
#endif
  }
  TraceSection(const TraceSection &) = delete;
  TraceSection &operator=(const TraceSection &) = delete;
};

}  // namespace sebtype
