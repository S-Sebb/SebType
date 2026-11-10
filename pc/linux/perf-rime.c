// Times Rime the way a keyboard uses it: one key, then read the candidate menu, per keystroke.
//   perf-rime SHARED_DIR USER_DIR SCHEMA RUNS < inputs.txt   (one key sequence per line)
// Prints key=value lines: deploy_ms (maintenance at start-up; a full deploy when USER_DIR has no
// build/), session_ms, first_key_us, key_p50_us, key_p95_us, key_max_us, keys, rss_kb, peak_rss_kb.
// Built by perf.sh against librime's public headers; nothing is committed, so nothing is learned.
// On Windows (pc/windows/stage.sh, MinGW) it loads Weasel's rime.dll from PATH.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rime_api.h"
#ifdef _WIN32
#include <windows.h>
#include <psapi.h>

static double now_us(void) {
  LARGE_INTEGER t, f;
  QueryPerformanceCounter(&t);
  QueryPerformanceFrequency(&f);
  return (double)t.QuadPart * 1e6 / f.QuadPart;
}

static long status_kb(const char *key) { // the Linux names, from the working set
  PROCESS_MEMORY_COUNTERS m;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), &m, sizeof m)) return 0;
  return (long)((strcmp(key, "VmHWM:") ? m.WorkingSetSize : m.PeakWorkingSetSize) / 1024);
}
#else
#include <dlfcn.h>
#include <time.h>

static double now_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static long status_kb(const char *key) {
  FILE *f = fopen("/proc/self/status", "r");
  char line[256];
  long v = 0;
  while (f && fgets(line, sizeof line, f))
    if (!strncmp(line, key, strlen(key))) v = atol(line + strlen(key));
  if (f) fclose(f);
  return v;
}
#endif

static int cmp(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  if (argc != 5) { fprintf(stderr, "usage: perf-rime SHARED USER SCHEMA RUNS < inputs\n"); return 2; }
  // rime-ice needs librime-lua, which Fcitx5's Rime also loads; Weasel's rime.dll has it built in.
  const char *modules[] = {"default", "plugins", "lua", NULL};
#ifdef _WIN32
  HMODULE rime = LoadLibraryA("rime.dll");
  RimeApi *(*get_api)(void) = rime ? (RimeApi * (*)(void)) GetProcAddress(rime, "rime_get_api") : NULL;
  if (!get_api) { fprintf(stderr, "rime.dll not found on PATH\n"); return 1; }
  RimeApi *api = get_api();
#else
  if (!dlopen("/usr/lib64/rime-plugins/librime-lua.so", RTLD_NOW | RTLD_GLOBAL)) modules[2] = NULL;
  RimeApi *api = rime_get_api();
#endif
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.app_name = "rime.sebtype-perf";
  traits.modules = modules;
  traits.min_log_level = 3;
  api->setup(&traits);
  api->initialize(&traits);
  double t = now_us();
  if (api->start_maintenance(True)) api->join_maintenance_thread();
  printf("deploy_ms=%.0f\n", (now_us() - t) / 1e3);

  t = now_us();
  RimeSessionId s = api->create_session();
  if (!api->select_schema(s, argv[3])) { fprintf(stderr, "schema %s not found\n", argv[3]); return 1; }
  printf("session_ms=%.1f\n", (now_us() - t) / 1e3);

  char inputs[64][128];
  int n = 0;
  while (n < 64 && scanf("%127s", inputs[n]) == 1) n++;
  int runs = atoi(argv[4]), keys = 0;
  double *us = malloc(sizeof(double) * runs * n * 128);
  for (int r = 0; r < runs; r++)
    for (int i = 0; i < n; i++) {
      api->clear_composition(s);
      for (char *c = inputs[i]; *c; c++) {
        t = now_us();
        api->process_key(s, *c, 0);
        RIME_STRUCT(RimeContext, ctx);
        if (api->get_context(s, &ctx)) api->free_context(&ctx);
        us[keys++] = now_us() - t;
      }
    }
  api->clear_composition(s);
  printf("first_key_us=%.0f\n", us[0]);
  qsort(us, keys, sizeof(double), cmp);
  printf("key_p50_us=%.0f\nkey_p95_us=%.0f\nkey_max_us=%.0f\nkeys=%d\n",
         us[keys / 2], us[(int)(keys * 0.95)], us[keys - 1], keys);
  printf("rss_kb=%ld\npeak_rss_kb=%ld\n", status_kb("VmRSS:"), status_kb("VmHWM:"));
  api->destroy_session(s);
  api->finalize();
  return 0;
}
