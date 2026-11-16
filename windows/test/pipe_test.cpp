// The text service's calls to a server that stops answering and then answers again (windows/src/pipe.h,
// #275): one key waits, the following ones don't and never reach it, and once it answers keys go through
// again; a server that is gone while waited for lets the text service start a new one. Uses the real pipe
// name, so it skips while a SebType server runs. windows/build.ps1 runs it; it also builds with MinGW:
//   x86_64-w64-mingw32-g++ -std=c++20 -O2 -static -I windows/src -I core/include windows/test/pipe_test.cpp -o pipe-test.exe
// MIT, SebType.
#include "pipe.h"

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <thread>

using namespace sebtype;
using namespace sebtype::win;

namespace {

int failures = 0;
#define CHECK(cond)                                                \
  do {                                                             \
    if (!(cond)) {                                                 \
      std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); \
      ++failures;                                                  \
    }                                                              \
  } while (0)

std::atomic<bool> hang{false}, stop{false};
std::atomic<int> keys{0};  // Key requests the server got

// Each connection: reads the request and replies, unless it hangs, then only once it no longer does.
void serve(HANDLE pipe) {
  std::string in;
  char buf[4096];
  DWORD n = 0;
  for (bool more = true; more;) {
    more = false;
    if (ReadFile(pipe, buf, sizeof(buf), &n, nullptr)) in.append(buf, n);
    else if (GetLastError() == ERROR_MORE_DATA) in.append(buf, n), more = true;
  }
  Request q;
  if (decode(in, q)) {
    if (q.op == Op::Key) ++keys;
    while (hang && !stop) Sleep(10);
    Reply r;
    r.taken = true;
    const std::string out = encode(r);
    WriteFile(pipe, out.data(), static_cast<DWORD>(out.size()), &n, nullptr);
    FlushFileBuffers(pipe);
  }
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
}

HANDLE instance() {
  return CreateNamedPipeW(pipeName().c_str(), PIPE_ACCESS_DUPLEX, PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
                          PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, nullptr);
}

// The next instance is made as soon as a client connects, so the next call never finds no pipe (which is
// a server that is gone, not one that hangs).
void server() {
  HANDLE pipe = instance();
  while (!stop) {
    if (ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED) {
      HANDLE next = instance();
      if (stop) {
        CloseHandle(pipe);
        pipe = next;
        break;
      }
      std::thread(serve, pipe).detach();
      pipe = next;
    } else {
      CloseHandle(pipe);
      pipe = instance();
    }
  }
  CloseHandle(pipe);
}

Request key() {
  Request q{Op::Key};
  q.key = {'a', 0, false};
  return q;
}

// Milliseconds a call took, its result and last error.
struct Took {
  DWORD ms;
  bool ok;
  DWORD error;
};
Took timed(Guarded &g) {
  Reply r;
  const DWORD start = GetTickCount();
  const bool ok = g.call(key(), r);
  return {GetTickCount() - start, ok, GetLastError()};
}

}  // namespace

int main() {
  Reply r;
  if (call(Request{Op::State}, r, 0, 200)) {
    std::printf("SKIP a SebType server runs\n");
    return 0;
  }
  std::thread(server).detach();
  Sleep(100);
  Guarded g(500, 300, 50);

  Took t = timed(g);
  CHECK(t.ok && !g.down());

  // It stops answering: the first key waits replyMs, the next ones fail at once and don't reach it.
  hang = true;
  t = timed(g);
  std::printf("first key to a hung server: %lu ms\n", t.ms);
  CHECK(!t.ok && t.error == ERROR_TIMEOUT && t.ms >= 450 && g.down());
  const int reached = keys;
  DWORD slowest = 0, total = 0;
  for (int i = 0; i < 20; ++i) {
    t = timed(g);
    CHECK(!t.ok && t.error == ERROR_TIMEOUT);
    slowest = std::max(slowest, t.ms);
    total += t.ms;
    Sleep(20);
  }
  std::printf("next 20 keys: %lu ms in all, slowest %lu ms (before #275: 20 x 5000 ms)\n", total, slowest);
  CHECK(slowest <= 100 && keys == reached);

  // It answers again: within retryMs a key goes through.
  hang = false;
  Sleep(350);
  t = timed(g);
  std::printf("first key after it answers again: %lu ms\n", t.ms);
  CHECK(t.ok && !g.down() && keys == reached + 1);

  // It hangs, then is gone: the text service may start a new one (no ERROR_TIMEOUT).
  hang = true;
  t = timed(g);
  CHECK(!t.ok && g.down());
  stop = true;
  call(Request{Op::State}, r, 0, 50);  // ends the server's wait for a connection
  Sleep(350);
  t = timed(g);
  CHECK(!t.ok && t.error != ERROR_TIMEOUT && !g.down());

  std::printf(failures ? "pipe test: %d failed\n" : "pipe test: all passed\n", failures);
  return failures ? 1 : 0;
}
