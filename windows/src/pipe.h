// SebType on Windows: the server's named pipe, one per user and session, and a call over it. MIT, SebType.
#pragma once

#include "protocol.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <string>

namespace sebtype::win {

// \\.\pipe\SebType.<session>.<user>: apps of every integrity level and app container in the session reach it
// (the server's security descriptor), other users and sessions have their own.
inline std::wstring pipeName() {
  DWORD session = 0;
  ProcessIdToSessionId(GetCurrentProcessId(), &session);
  wchar_t user[257] = L"";
  DWORD n = 257;
  GetUserNameW(user, &n);
  return L"\\\\.\\pipe\\SebType." + std::to_wstring(session) + L"." + user;
}

// Sends one request and reads the reply. False when no server takes it within connectMs, or (last error
// ERROR_TIMEOUT) when it doesn't reply within replyMs: a server that hangs costs an app that much, not
// its keyboard, and the request may still be carried out, so it isn't sent again.
inline bool call(const Request &request, Reply &reply, DWORD connectMs = 1000, DWORD replyMs = 5000) {
  static const std::wstring name = pipeName();
  HANDLE pipe = INVALID_HANDLE_VALUE;
  for (DWORD waited = 0;; waited += 50) {
    pipe = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                       FILE_FLAG_OVERLAPPED | SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_PIPE_BUSY || waited >= connectMs) return false;
    WaitNamedPipeW(name.c_str(), 50);
  }
  OVERLAPPED o{};
  o.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
  const DWORD start = GetTickCount();
  // Finishes one read or write within what is left of replyMs; ERROR_MORE_DATA stays the last error.
  auto finish = [&](BOOL done, DWORD &n) {
    if (done || GetLastError() != ERROR_IO_PENDING) return done != FALSE;
    const DWORD spent = GetTickCount() - start;
    if (WaitForSingleObject(o.hEvent, spent < replyMs ? replyMs - spent : 0) != WAIT_OBJECT_0) {
      CancelIo(pipe);
      GetOverlappedResult(pipe, &o, &n, TRUE);
      SetLastError(ERROR_TIMEOUT);
      return false;
    }
    return GetOverlappedResult(pipe, &o, &n, FALSE) != FALSE;
  };
  DWORD mode = PIPE_READMODE_MESSAGE, n = 0;
  const std::string out = encode(request);
  bool ok = SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr) &&
            finish(WriteFile(pipe, out.data(), static_cast<DWORD>(out.size()), &n, &o), n) && n == out.size();
  std::string in;
  char buf[16384];
  for (bool more = ok; more;) {
    more = false;
    if (finish(ReadFile(pipe, buf, sizeof(buf), &n, &o), n)) {
      in.append(buf, n);
    } else if (GetLastError() == ERROR_MORE_DATA) {
      in.append(buf, n);
      more = true;
    } else {
      ok = false;
    }
  }
  const DWORD error = GetLastError();
  CloseHandle(o.hEvent);
  CloseHandle(pipe);
  SetLastError(error);
  return ok && decode(in, reply);
}

inline std::wstring utf16(const std::string &s) {
  if (s.empty()) return {};
  std::wstring w(MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), nullptr, 0), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()), w.data(), static_cast<int>(w.size()));
  return w;
}

inline std::string utf8(const std::wstring &w) {
  if (w.empty()) return {};
  std::string s(WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr),
                '\0');
  WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), static_cast<int>(s.size()), nullptr,
                      nullptr);
  return s;
}

}  // namespace sebtype::win
