// SebType on Windows: the one server per user and session. It hosts the core (librime in this process,
// Mozc through its own mozc_server) for the text service in every app, which reach it over a named pipe:
// one process, so Rime's learned words have one writer, and one language and state for every window.
// MIT, SebType.
//
//   sebtype-server.exe                       serves (started at logon, or by the text service)
//   sebtype-server.exe /deploy|/sync|/quit   tells the server (/deploy and /sync do it themselves when none
//                                            runs, and return when Rime is done), for setup and the Configurator;
//                                            exit codes: 2 no mutex, 3 the server didn't answer, 4 it
//                                            didn't take the request, 5 Rime still busy after 5 minutes
#include <sebtype/core.h>
#include <sebtype/hosts.h>

#include "pipe.h"

#include <sddl.h>
#include <shlobj.h>

#include <filesystem>
#include <fstream>
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

// %TEMP%\rime.sebtype, where Weasel logged (#129): Rime's log and the server's own (it has no console).
std::filesystem::path logDir() {
  wchar_t temp[MAX_PATH];
  const auto dir = std::filesystem::path(std::wstring(temp, GetTempPathW(MAX_PATH, temp))) / L"rime.sebtype";
  std::error_code e;
  std::filesystem::create_directories(dir, e);
  return dir;
}

// One line in server.log: starts, slow requests and the command line's failures, for bug reports.
void note(const std::string &line) {
  SYSTEMTIME t;
  GetLocalTime(&t);
  char stamp[32];
  snprintf(stamp, sizeof(stamp), "%02d-%02d %02d:%02d:%02d.%03d %lu ", t.wMonth, t.wDay, t.wHour, t.wMinute,
           t.wSecond, t.wMilliseconds, GetCurrentProcessId());
  std::ofstream(logDir() / L"server.log", std::ios::app) << stamp << line << "\n";
}

std::unique_ptr<Engine> makeEngine(Lang lang) {
  // The folders SebType's Weasel and Mozc used, so learned words and settings carry over.
  if (lang == Lang::Chinese)
    return makeRime({u8(exeDir() / L"data"), u8(knownFolder(FOLDERID_RoamingAppData) / L"Rime"), u8(logDir())});
  if (lang == Lang::Japanese)
    return makeMozc({u8(exeDir() / L"mozc_server.exe"), u8(knownFolder(FOLDERID_LocalAppDataLow) / L"Mozc")});
  return nullptr;
}

// One server per user and session (Local: this session's namespace); /deploy and /sync take it while they
// stand in for one.
constexpr wchar_t kServerMutex[] = L"Local\\SebType.Server";
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
  const DWORD asked = GetTickCount();
  std::lock_guard<std::mutex> hold(lock);
  const DWORD started = GetTickCount();
  struct Slow {  // a request that took over a second: what waited and what worked
    const Request &q;
    DWORD asked, started;
    ~Slow() {
      const DWORD done = GetTickCount();
      if (done - asked > 1000)
        note("op " + std::to_string(static_cast<int>(q.op)) + " lang " + std::to_string(static_cast<int>(q.lang)) +
             ": waited " + std::to_string(started - asked) + " ms, took " + std::to_string(done - started) + " ms");
    }
  } slow{q, asked, started};
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
  HANDLE single = CreateMutexW(nullptr, TRUE, kServerMutex);
  if (!single || GetLastError() == ERROR_ALREADY_EXISTS) return 0;
  HANDLE token = nullptr;
  TOKEN_ELEVATION elevated{};
  DWORD n = 0;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    GetTokenInformation(token, TokenElevation, &elevated, sizeof(elevated), &n);
    CloseHandle(token);
  }
  note(std::string("server started") + (elevated.TokenIsElevated ? ", elevated" : ""));
  Core host(makeEngine);
  core = &host;
  // The popup's words in Windows' display language when it is 中文 or 日本語 (#205).
  const LANGID ui = PRIMARYLANGID(GetUserDefaultUILanguage());
  host.setUiLanguage(ui == LANG_CHINESE ? Lang::Chinese : ui == LANG_JAPANESE ? Lang::Japanese : Lang::English);
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
  using namespace sebtype;
  using namespace sebtype::win;
  const std::wstring arg = args ? args : L"";
  Request q;
  if (arg == L"/deploy") q.op = Op::Deploy;
  else if (arg == L"/sync") q.op = Op::Sync;
  else if (arg == L"/quit") q.op = Op::Quit;
  else return run();
  Reply r;
  if (q.op == Op::Quit) return call(q, r, 5000), 0;
  const auto failed = [&](int code, const char *what) {
    note(std::string(utf8(arg)) + ": " + what + " (error " + std::to_string(GetLastError()) + "), exit " + std::to_string(code));
    return code;
  };
  if (!call(Request{Op::State}, r, 5000)) {
    // No server: Rime does it here, as Weasel's deployer did, and no server is left running (one started
    // from an elevated Setup would be out of the apps' reach). Holding the server's mutex keeps a second
    // Rime from starting meanwhile; an app's next key starts the server after.
    HANDLE single = CreateMutexW(nullptr, TRUE, kServerMutex);
    if (!single) return failed(2, "no mutex");
    if (GetLastError() != ERROR_ALREADY_EXISTS) {
      Engine *rime = makeEngine(Lang::Chinese).release();  // never finalized: exiting ends Rime's thread
      q.op == Op::Deploy ? rime->deploy() : rime->save();
      for (DWORD start = GetTickCount(); rime->busy(); Sleep(200))
        if (GetTickCount() - start > 300000) return failed(5, "Rime still busy after 5 minutes");
      return 0;
    }
    // A server is starting: until it answers.
    CloseHandle(single);
    bool up = false;
    for (int i = 0; i < 100 && !up; ++i) {
      Sleep(100);
      up = call(Request{Op::State}, r, 5000);
    }
    if (!up) return failed(3, "the server didn't answer");
  }
  if (!call(q, r, 5000, 60000)) return failed(4, "the server didn't take the request");
  // Until Rime is done: setup's typing and the Configurator's next step need it.
  for (DWORD start = GetTickCount(); r.busy; Sleep(200)) {
    if (GetTickCount() - start > 300000) return failed(5, "Rime still busy after 5 minutes");
    if (!call(Request{Op::State}, r, 5000)) return failed(3, "the server didn't answer");
  }
  return 0;
}
