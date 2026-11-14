// SebType on Windows: the one server per user and session. It hosts the core (librime in this process,
// Mozc through its own mozc_server) for the text service in every app, which reach it over a named pipe:
// one process, so Rime's learned words have one writer, and one language and state for every window.
// MIT, SebType.
//
//   sebtype-server.exe                       serves (started at logon, or by the text service)
//   sebtype-server.exe /deploy|/sync|/quit   tells the server (/deploy and /sync start one when none runs,
//                                            and return when Rime is done), for setup and the Configurator
#include <sebtype/core.h>
#include <sebtype/hosts.h>

#include "pipe.h"

#include <sddl.h>
#include <shlobj.h>

#include <filesystem>
#include <mutex>
#include <thread>

namespace sebtype::win {
namespace {

std::filesystem::path knownFolder(REFKNOWNFOLDERID id) {
  PWSTR p = nullptr;
  std::filesystem::path path;
  if (SUCCEEDED(SHGetKnownFolderPath(id, 0, nullptr, &p))) path = p;
  CoTaskMemFree(p);
  return path;
}

std::filesystem::path exeDir() {
  wchar_t p[MAX_PATH];
  GetModuleFileNameW(nullptr, p, MAX_PATH);
  return std::filesystem::path(p).parent_path();
}

std::string u8(const std::filesystem::path &p) { return utf8(p.wstring()); }

std::unique_ptr<Engine> makeEngine(Lang lang) {
  // The folders SebType's Weasel and Mozc used, so learned words and settings carry over.
  if (lang == Lang::Chinese) return makeRime({u8(exeDir() / L"data"), u8(knownFolder(FOLDERID_RoamingAppData) / L"Rime")});
  if (lang == Lang::Japanese)
    return makeMozc({u8(exeDir() / L"mozc_server.exe"), u8(knownFolder(FOLDERID_LocalAppDataLow) / L"Mozc")});
  return nullptr;
}

std::mutex lock;
Core *core = nullptr;

Reply state(bool taken, std::string commit = {}) {
  Reply r;
  r.taken = taken;
  r.commit = commit + core->takeCommit();
  r.preedit = core->preedit();
  r.page = core->page();
  r.aux = core->aux();
  r.lang = core->language();
  r.icon = core->icon();
  r.menu = core->menu();
  r.notice = core->takeNotice(true);
  core->forEachEngine([&](Engine &e) { r.busy = r.busy || e.busy(); });
  return r;
}

Reply handle(const Request &q) {
  std::lock_guard<std::mutex> hold(lock);
  bool taken = false;
  std::string commit;
  switch (q.op) {
    case Op::Key: taken = core->key(q.key); break;
    case Op::Select: core->select(q.index); break;
    case Op::Page: core->changePage(q.next); break;
    case Op::FocusOut: core->focusOut(); break;
    case Op::FocusIn:  // each app may have its own language (Windows' per-app input setting)
    case Op::Language:
      if (core->language() != q.lang) core->selectLanguage(q.lang);
      core->takeNotice(true);  // Windows shows its own switcher
      break;
    case Op::Menu: {
      const auto menu = core->menu();
      if (q.index >= 0 && q.index < static_cast<int>(menu.size())) core->activate(menu[q.index]);
      break;
    }
    case Op::Latin:
      // As Weasel's and Mozc's buttons did; what was being typed goes in as letters.
      if (Engine *e = core->engine(core->language())) {
        e->setLatin(!e->latin());
        commit = e->takeCommit();
      }
      break;
    case Op::State: break;
    case Op::Deploy:  // Rime's, started for it when no app has typed Chinese yet
      core->engine(Lang::Chinese)->deploy();
      break;
    case Op::Sync:
      core->engine(Lang::Chinese);
      core->forEachEngine([](Engine &e) { e.save(); });
      break;
    case Op::Quit: break;
  }
  return state(taken, commit);
}

// Apps at any integrity level and in app containers (all application packages, and the restricted ones)
// may connect; the low mandatory label lets low-integrity apps write to it.
SECURITY_ATTRIBUTES *pipeSecurity() {
  static SECURITY_ATTRIBUTES sa{sizeof(sa), nullptr, FALSE};
  if (!sa.lpSecurityDescriptor)
    ConvertStringSecurityDescriptorToSecurityDescriptorW(
        L"D:(A;;GA;;;OW)(A;;GA;;;SY)(A;;GA;;;AC)(A;;GA;;;S-1-15-2-2)S:(ML;;NW;;;LW)", SDDL_REVISION_1,
        &sa.lpSecurityDescriptor, nullptr);
  return &sa;
}

void serve(HANDLE pipe) {
  std::string in;
  char buf[4096];
  DWORD n = 0;
  for (bool more = true; more;) {
    more = false;
    if (ReadFile(pipe, buf, sizeof(buf), &n, nullptr)) {
      in.append(buf, n);
    } else if (GetLastError() == ERROR_MORE_DATA) {
      in.append(buf, n);
      more = true;
    } else {
      in.clear();
    }
  }
  Request q;
  if (!in.empty() && decode(in, q)) {
    const std::string out = encode(handle(q));
    if (WriteFile(pipe, out.data(), static_cast<DWORD>(out.size()), &n, nullptr)) FlushFileBuffers(pipe);
    if (q.op == Op::Quit) {
      std::lock_guard<std::mutex> hold(lock);
      core->forEachEngine([](Engine &e) { e.save(); });
      ExitProcess(0);
    }
  }
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
}

int run() {
  // One server per user and session; a second one leaves at once.
  HANDLE single = CreateMutexW(nullptr, TRUE, L"Local\\SebType.Server");  // Local: this session
  if (!single || GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  Core host(makeEngine);
  core = &host;
  const std::wstring name = pipeName();
  for (;;) {
    HANDLE pipe = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX,
                                   PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                   PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, pipeSecurity());
    if (pipe == INVALID_HANDLE_VALUE) return 1;
    if (ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED) {
      std::thread(serve, pipe).detach();  // an app that stops mid-call holds up only its own thread
    } else {
      CloseHandle(pipe);
    }
  }
}

}  // namespace
}  // namespace sebtype::win

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR args, int) {
  using namespace sebtype::win;
  const std::wstring arg = args ? args : L"";
  Request q;
  if (arg == L"/deploy") q.op = Op::Deploy;
  else if (arg == L"/sync") q.op = Op::Sync;
  else if (arg == L"/quit") q.op = Op::Quit;
  else return run();
  Reply r;
  if (q.op == Op::Quit) return call(q, r, 5000), 0;
  if (!call(q, r, 5000)) {
    // No server: start one as this user, as a text service would.
    wchar_t self[MAX_PATH];
    GetModuleFileNameW(nullptr, self, MAX_PATH);
    STARTUPINFOW si{sizeof(si)};
    PROCESS_INFORMATION pi{};
    std::wstring cmd = L"\"" + std::wstring(self) + L"\"";
    if (!CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, DETACHED_PROCESS, nullptr, nullptr, &si, &pi))
      return 1;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    bool sent = false;
    for (int i = 0; i < 100 && !sent; ++i) {
      Sleep(100);
      sent = call(q, r, 5000);
    }
    if (!sent) return 1;
  }
  // Until Rime is done: setup's typing and the Configurator's next step need it.
  for (DWORD start = GetTickCount(); r.busy; Sleep(200)) {
    if (GetTickCount() - start > 300000 || !call(Request{Op::State}, r, 5000)) return 1;
  }
  return 0;
}
