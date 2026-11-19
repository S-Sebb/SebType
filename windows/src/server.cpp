// SebType on Windows: the one server per user and session. It hosts the core (librime and Mozc in this
// process; Mozc in sebtype-mozc.dll, loaded at the first 日本語 key) for the text service in every app, which
// reach it over a named pipe: one process, so the learned words have one writer, and one language and state
// for every window. MIT, SebType.
//
//   sebtype-server.exe [/error:N]                 serves (started at logon, or by the text service, with the
//                                                 error its call met, for server.log)
//   sebtype-server.exe /deploy|/sync|/quit|/mozc  tells the server (/deploy and /sync do it themselves when
//                                                 none runs, and return when Rime is done), for setup and the
//                                                 Configurator; /mozc: Mozc reads its files again;
//                                                 exit codes: 2 no mutex, 3 the server didn't answer, 4 it
//                                                 didn't take the request, 5 Rime still busy after 5 minutes
#include <sebtype/core.h>
#include <sebtype/hosts.h>

#include "pipe.h"

#include <sddl.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>

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

// Which program started this one, for server.log.
std::string parent() {
  const DWORD self = GetCurrentProcessId();
  DWORD ppid = 0;
  HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
  PROCESSENTRY32W e{sizeof(e)};
  for (BOOL ok = Process32FirstW(snap, &e); ok && !ppid; ok = Process32NextW(snap, &e))
    if (e.th32ProcessID == self) ppid = e.th32ParentProcessID;
  std::string name = "?";
  for (BOOL ok = Process32FirstW(snap, &e); ok; ok = Process32NextW(snap, &e))
    if (e.th32ProcessID == ppid) name = utf8(e.szExeFile);
  CloseHandle(snap);
  return name + " " + std::to_string(ppid);
}

std::unique_ptr<Engine> makeEngine(Lang lang) {
  // The folders SebType's Weasel and Mozc (and its mozc_server.exe before #233) used, so learned words and
  // settings carry over.
  if (lang == Lang::Chinese)
    return makeRime({u8(exeDir() / L"data"), u8(knownFolder(FOLDERID_RoamingAppData) / L"Rime"), u8(logDir())});
  // Mozc loads in its own thread, and 日本語 is grey until then (#312).
  if (lang == Lang::Japanese) {
    MozcPaths paths{u8(knownFolder(FOLDERID_LocalAppDataLow) / L"Mozc"), u8(knownFolder(FOLDERID_RoamingAppData) / L"Rime")};
    paths.preload = u8(exeDir() / L"sebtype-mozc.dll");
    return makeMozc(paths);
  }
  return nullptr;
}

// One server per user and session (Local: this session's namespace); /deploy and /sync take it while they
// stand in for one.
constexpr wchar_t kServerMutex[] = L"Local\\SebType.Server";
std::mutex lock;
Core *core = nullptr;
Composer composer;  // under lock

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
  r.busy = core->choresWait();
  core->forEachEngine([&](Engine &e) { r.busy = r.busy || e.busy(); });
  return r;
}

// A private field (#270) learns nothing new. server.log notes each change, which the tests read.
void followField(bool learning) {
  if (core->fieldLearning() == learning) return;
  core->setField(Field::Text, learning);
  note(learning ? "field: learns" : "field: private, learns nothing");
}

Reply handle(const Request &q, HANDLE pipe) {
  const DWORD asked = GetTickCount();
  std::lock_guard<std::mutex> hold(lock);
  const DWORD started = GetTickCount();
  // The app stopped waiting (pipe.h's Guarded) and typed the key itself: done now, it would go in twice (#275).
  if (clientGone(pipe)) {
    note("op " + std::to_string(static_cast<int>(q.op)) + ": dropped, the app stopped waiting after " +
         std::to_string(started - asked) + " ms");
    return {};
  }
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
  const bool reset = composer.resets(q);
  bool taken = false;
  std::string commit;
  switch (q.op) {
    case Op::Key:  // in the app's language: the apps share one core, and another app's focus may have moved it
      if (core->language() != q.lang) {
        core->selectLanguage(q.lang);
        core->takeNotice(true);
      }
      followField(q.learning);
      taken = core->key(q.key);
      break;
    case Op::Select: core->select(q.index); break;
    case Op::Page: core->changePage(q.next); break;
    case Op::FocusOut: core->focusOut(); break;
    case Op::FocusIn:  // each app may have its own language (Windows' per-app input setting)
      followField(q.learning);
      [[fallthrough]];
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
    case Op::Ready: {  // not state(): it would take the notice, and the commit, meant for the app that typed
      Reply r;
      r.lang = q.lang;
      r.icon = core->icon(q.lang);
      return r;
    }
    case Op::Reset:
      if (reset) core->clear();
      else note("reset: kept, another app has typed since");
      break;
    // These drop what is being typed, so they wait until typing is idle (#373); runChores does them.
    case Op::Deploy:  // Rime's, started for it when no app has typed Chinese yet; Mozc's page size
      core->whenIdle(Core::Chore::Deploy, [] {
        core->engine(Lang::Chinese);
        core->forEachEngine([](Engine &e) { e.deploy(); });
      });
      break;
    case Op::Sync:
      core->whenIdle(Core::Chore::Save, [] {
        core->engine(Lang::Chinese);
        core->forEachEngine([](Engine &e) { e.save(); });
      });
      break;
    case Op::Quit: break;
    case Op::Mozc:  // in the background: 日本語 is grey until it is done (#312)
      core->whenIdle(Core::Chore::ReloadJapanese, [] {
        if (Engine *mozc = core->running(Lang::Japanese)) mozc->reload();
      });
      break;
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
    const std::string out = encode(handle(q, pipe));
    if (WriteFile(pipe, out.data(), static_cast<DWORD>(out.size()), &n, nullptr)) FlushFileBuffers(pipe);
    if (q.op == Op::Quit) {
      std::lock_guard<std::mutex> hold(lock);
      note(q.client ? "quit, asked by app " + std::to_string(q.client) : "quit, asked by /quit");
      core->forEachEngine([](Engine &e) { e.save(); });
      // Not ExitProcess: its DLL detach and librime's static destructors run after the other threads are
      // gone and could wait for one forever. A process stuck exiting can't be terminated (taskkill fails)
      // and keeps the Rime tables mapped, so Setup couldn't replace them (#190).
      TerminateProcess(GetCurrentProcess(), 0);
    }
  }
  DisconnectNamedPipe(pipe);
  CloseHandle(pipe);
}

int run() {
  HANDLE token = nullptr;
  TOKEN_ELEVATION elevated{};
  DWORD session = 0, n = 0;
  if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
    GetTokenInformation(token, TokenElevation, &elevated, sizeof(elevated), &n);
    GetTokenInformation(token, TokenSessionId, &session, sizeof(session), &n);
    CloseHandle(token);
  }
  const std::string origin = std::string(elevated.TokenIsElevated ? "elevated, " : "") + "session " +
                             std::to_string(session) + ", by " + parent();
  // One server per user and session; a second one leaves at once.
  HANDLE single = CreateMutexW(nullptr, TRUE, kServerMutex);
  if (const DWORD error = GetLastError(); !single || error == ERROR_ALREADY_EXISTS) {
    // Let go first: while this handle is open, the mutex stays, and a server started meanwhile leaves too.
    if (single) CloseHandle(single);
    note("second server (" + origin + "): left, the mutex " + (single ? "is taken" : "failed, error " + std::to_string(error)));
    return 0;
  }
  note("server started (" + origin + "): " + utf8(GetCommandLineW()));
  Core host(makeEngine);
  core = &host;
  // The popup's words in Windows' display language when it is 中文 or 日本語 (#205).
  const LANGID ui = PRIMARYLANGID(GetUserDefaultUILanguage());
  host.setUiLanguage(ui == LANG_CHINESE ? Lang::Chinese : ui == LANG_JAPANESE ? Lang::Japanese : Lang::English);
  // The deploys, syncs and Mozc reloads asked for, once typing is idle (#373).
  std::thread([] {
    for (;; Sleep(1000)) {
      std::lock_guard<std::mutex> hold(lock);
      core->runChores();
    }
  }).detach();
  const std::wstring name = pipeName();
  const auto instance = [&] {
    HANDLE pipe = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX,
                                   PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                                   PIPE_UNLIMITED_INSTANCES, 65536, 65536, 0, pipeSecurity());
    if (pipe == INVALID_HANDLE_VALUE) note("no pipe, error " + std::to_string(GetLastError()));
    return pipe;
  };
  // The next instance is made as an app connects, as pipe_test's server does (#303): made only after the
  // connection's thread started, a quick call could end first and leave no instance, and the next app's call
  // would find no pipe, as if no server ran, and start a second one only to see it leave.
  for (HANDLE pipe = instance(); pipe != INVALID_HANDLE_VALUE;) {
    const bool connected = ConnectNamedPipe(pipe, nullptr) || GetLastError() == ERROR_PIPE_CONNECTED;
    HANDLE next = instance();
    if (connected) std::thread(serve, pipe).detach();  // an app that stops mid-call holds up only its own thread
    else CloseHandle(pipe);
    pipe = next;
  }
  return 1;
}

}  // namespace
}  // namespace sebtype::win

int WINAPI wWinMain(HINSTANCE, HINSTANCE, PWSTR, int) {
  using namespace sebtype;
  using namespace sebtype::win;
  // From the whole command line: wWinMain's own argument came differently on Windows than under Wine, and
  // /deploy from setup.ps1 started a server that never returned.
  int argc = 0;
  wchar_t **argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  const std::wstring arg = argv && argc > 1 ? argv[1] : L"";
  LocalFree(argv);
  Request q;
  if (_wcsicmp(arg.c_str(), L"/deploy") == 0) q.op = Op::Deploy;
  else if (_wcsicmp(arg.c_str(), L"/sync") == 0) q.op = Op::Sync;
  else if (_wcsicmp(arg.c_str(), L"/quit") == 0) q.op = Op::Quit;
  else if (_wcsicmp(arg.c_str(), L"/mozc") == 0) q.op = Op::Mozc;
  else return run();
  Reply r;
  // No server: no Mozc to tell, and it reads its files when one starts.
  if (q.op == Op::Quit || q.op == Op::Mozc) return call(q, r, 5000), 0;
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
      const DWORD start = GetTickCount();
      Engine *rime = makeEngine(Lang::Chinese).release();  // never finalized: exiting ends Rime's thread
      q.op == Op::Deploy ? rime->deploy() : rime->save();
      for (; rime->busy(); Sleep(200))
        if (GetTickCount() - start > 300000) return failed(5, "Rime still busy after 5 minutes");
      note(utf8(arg) + " in this process: " + std::to_string((GetTickCount() - start) / 1000) + " s");
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
