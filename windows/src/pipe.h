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

// Sends one request and reads the reply. False when no server answers within timeoutMs.
inline bool call(const Request &request, Reply &reply, DWORD timeoutMs = 1000) {
  static const std::wstring name = pipeName();
  HANDLE pipe = INVALID_HANDLE_VALUE;
  for (DWORD waited = 0;; waited += 50) {
    pipe = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                       SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (pipe != INVALID_HANDLE_VALUE) break;
    if (GetLastError() != ERROR_PIPE_BUSY || waited >= timeoutMs) return false;
    WaitNamedPipeW(name.c_str(), 50);
  }
  DWORD mode = PIPE_READMODE_MESSAGE, n = 0;
  const std::string out = encode(request);
  bool ok = SetNamedPipeHandleState(pipe, &mode, nullptr, nullptr) &&
            WriteFile(pipe, out.data(), static_cast<DWORD>(out.size()), &n, nullptr) && n == out.size();
  std::string in;
  char buf[16384];
  for (bool more = ok; more;) {
    more = false;
    if (ReadFile(pipe, buf, sizeof(buf), &n, nullptr)) {
      in.append(buf, n);
    } else if (GetLastError() == ERROR_MORE_DATA) {
      in.append(buf, n);
      more = true;
    } else {
      ok = false;
    }
  }
  CloseHandle(pipe);
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
