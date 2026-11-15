// SPDX-License-Identifier: BSD-3-Clause
// SebType core: the PCs' transport to Mozc, its own mozc_server over Mozc's IPC. Moved out of mozc.cpp, whose
// protocol use follows fcitx5-mozc (Copyright 2010-2018 Google Inc. and 2017 Weng Xuetian; fcitx/mozc's
// src/unix/fcitx5), so this file keeps its licence: see core/README.md.
#include "mozc_transport.h"

#ifndef _WIN32
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#endif

#include <algorithm>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <thread>
#include <utility>

#include "ipc/ipc.pb.h"

#ifdef _WIN32  // after the protocol's headers: its macros (DELETE, GetMessage) would clash with them
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#endif

namespace sebtype {

namespace {

using mozc::commands::Input;
using mozc::commands::Output;

// Mozc's IPC: one connection per call to the server named after the key it writes to
// <profile>/.session.ipc. On Linux an abstract Unix socket, the request ending at the write shutdown; on
// Windows a message-mode named pipe, one message each way (Mozc's ipc/win32_ipc.cc).
class Ipc final : public MozcTransport {
 public:
  explicit Ipc(MozcPaths paths) : paths_(std::move(paths)) {}

  bool call(const Input &in, Output &out) override {
    std::string request;
    in.SerializeToString(&request);
    std::string reply;
    if (!send(request, reply)) {
      // Not waited for again soon after a start it didn't answer: a broken server would cost every call 3 s.
      const auto now = std::chrono::steady_clock::now();
      if (now - launched_ < std::chrono::seconds(10)) return false;
      launched_ = now;
      launch();
      bool sent = false;
      for (int i = 0; i < 60 && !sent; ++i) {  // up to 3 s for a fresh server
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
        sent = send(request, reply);
      }
      if (!sent) return false;
    }
    return out.ParseFromString(reply);
  }

 private:
  std::string key() {
    mozc::ipc::IPCPathInfo info;
#ifdef _WIN32
    // session.ipc, no dot on Windows; the server holds it open to delete on close, so it opens only with
    // FILE_SHARE_DELETE (Mozc's ipc/ipc_path_manager.cc).
    HANDLE f = CreateFileW(std::filesystem::u8path(paths_.profileDir + "/session.ipc").c_str(), GENERIC_READ,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0, nullptr);
    if (f == INVALID_HANDLE_VALUE) return {};
    char buf[2096];
    DWORD n = 0;
    const bool read = ReadFile(f, buf, sizeof(buf), &n, nullptr);
    CloseHandle(f);
    if (!read || !info.ParseFromArray(buf, static_cast<int>(n))) return {};
#else
    std::ifstream f(std::filesystem::u8path(paths_.profileDir + "/.session.ipc"), std::ios::binary);
    if (!f || !info.ParseFromIstream(&f)) return {};
#endif
    return info.key();
  }

#ifdef _WIN32
  bool send(const std::string &request, std::string &reply) {
    const std::string key = this->key();
    if (key.empty()) return false;
    const std::string name = "\\\\.\\pipe\\mozc." + key + ".session";
    HANDLE pipe = CreateFileA(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                              FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return false;
    // Overlapped, for the 5 s Linux's socket has: a server that hangs mustn't hold up every app.
    OVERLAPPED o{};
    o.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    const DWORD start = GetTickCount();
    auto finish = [&](BOOL done, DWORD &n) {
      if (done || GetLastError() != ERROR_IO_PENDING) return done != FALSE;
      const DWORD spent = GetTickCount() - start;
      if (WaitForSingleObject(o.hEvent, spent < 5000 ? 5000 - spent : 0) != WAIT_OBJECT_0) {
        CancelIo(pipe);
        GetOverlappedResult(pipe, &o, &n, TRUE);
        SetLastError(ERROR_TIMEOUT);
        return false;
      }
      return GetOverlappedResult(pipe, &o, &n, FALSE) != FALSE;
    };
    DWORD mode = PIPE_READMODE_MESSAGE, n = 0;
    bool ok = SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr) &&
              finish(WriteFile(pipe, request.data(), static_cast<DWORD>(request.size()), &n, &o), n) &&
              n == request.size();
    reply.clear();
    char buf[65536];
    for (bool more = ok; more;) {
      more = false;
      if (finish(ReadFile(pipe, buf, sizeof(buf), &n, &o), n)) {
        reply.append(buf, n);
      } else if (GetLastError() == ERROR_MORE_DATA) {
        reply.append(buf, n);
        more = true;
      } else {
        ok = false;
      }
    }
    CloseHandle(o.hEvent);
    CloseHandle(pipe);
    return ok;
  }

  // Starts mozc_server on its own, as Mozc's client does: it outlives the host and stops when idle.
  // mozc_server refuses to run (exit 3) unless its main thread starts with an impersonation token, which
  // Mozc's launcher sets (server_launcher.cc, win_sandbox.cc). We hand it a copy of our own: the server
  // never runs elevated, so Mozc's further restrictions (no Administrators group) would change nothing.
  void launch() {
    std::wstring cmd = L"\"" + std::filesystem::u8path(paths_.server).wstring() + L"\"";
    HANDLE self = nullptr, impersonation = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_DUPLICATE, &self)) return;
    const bool copied = DuplicateTokenEx(self, TOKEN_IMPERSONATE | TOKEN_QUERY, nullptr, SecurityImpersonation,
                                         TokenImpersonation, &impersonation);
    CloseHandle(self);
    if (!copied) return;
    STARTUPINFOW si{sizeof(si)};
    PROCESS_INFORMATION pi{};
    if (CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE,
                       CREATE_SUSPENDED | CREATE_NO_WINDOW | DETACHED_PROCESS | CREATE_DEFAULT_ERROR_MODE, nullptr,
                       nullptr, &si, &pi)) {
      if (SetThreadToken(&pi.hThread, impersonation)) ResumeThread(pi.hThread);
      else TerminateProcess(pi.hProcess, 1);
      CloseHandle(pi.hThread);
      CloseHandle(pi.hProcess);
    }
    CloseHandle(impersonation);
  }
#else
  bool send(const std::string &request, std::string &reply) {
    const std::string key = this->key();
    if (key.empty()) return false;
    const std::string name = "tmp/.mozc." + key + ".session";
    int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) return false;
    sockaddr_un addr{};
    addr.sun_family = AF_UNIX;
    std::memcpy(addr.sun_path + 1, name.data(), std::min(name.size(), sizeof(addr.sun_path) - 1));
    const socklen_t len = sizeof(addr.sun_family) + 1 + name.size();
    timeval timeout{5, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    bool ok = connect(fd, reinterpret_cast<sockaddr *>(&addr), len) == 0;
    for (size_t sent = 0; ok && sent < request.size();) {
      ssize_t n = write(fd, request.data() + sent, request.size() - sent);
      ok = n > 0;
      sent += ok ? n : 0;
    }
    ok = ok && shutdown(fd, SHUT_WR) == 0;
    reply.clear();
    char buf[65536];
    for (ssize_t n; ok && (n = read(fd, buf, sizeof(buf))) != 0;) {
      ok = n > 0;
      if (ok) reply.append(buf, n);
    }
    close(fd);
    return ok;
  }

  // Starts mozc_server on its own, as Mozc's client does: it outlives Fcitx5 and stops when idle.
  void launch() {
    pid_t pid = fork();
    if (pid == 0) {
      if (fork() == 0) {
        setsid();
        int null = open("/dev/null", O_RDWR);
        dup2(null, 0), dup2(null, 1), dup2(null, 2);
        execl(paths_.server.c_str(), paths_.server.c_str(), static_cast<char *>(nullptr));
      }
      _exit(0);
    }
    if (pid > 0) waitpid(pid, nullptr, 0);
  }
#endif

  MozcPaths paths_;
  std::chrono::steady_clock::time_point launched_{};
};

}  // namespace

std::unique_ptr<MozcTransport> makeMozcTransport(const MozcPaths &paths) { return std::make_unique<Ipc>(paths); }

}  // namespace sebtype
