// Types each "keys<TAB>expected" line of INPUT one key at a time, reading the candidate menu after
// every key as the keyboard does, and prints the rank of expected among the first page (-1: not
// there). Nothing is committed, so nothing is learned between lines.
//   rimebench SHARED USER SCHEMA INPUT [PLUGIN.so ...]   stderr: key_p50_us, key_p95_us, rss_kb
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include "rime_api.h"

static double now_us(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e6 + t.tv_nsec / 1e3;
}

static int cmp(const void *a, const void *b) {
  double x = *(const double *)a, y = *(const double *)b;
  return (x > y) - (x < y);
}

int main(int argc, char **argv) {
  if (argc < 5) { fprintf(stderr, "usage: rimebench SHARED USER SCHEMA INPUT [PLUGIN.so ...]\n"); return 2; }
  const char *modules[8] = {"default"};
  int m = 1;
  for (int i = 5; i < argc && m < 7; ++i) {
    if (!dlopen(argv[i], RTLD_NOW | RTLD_GLOBAL)) { fprintf(stderr, "%s\n", dlerror()); return 3; }
    modules[m++] = strstr(argv[i], "octagram") ? "octagram" : "lua";
  }
  RimeApi *api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.app_name = "rime.sebtype-bench";
  traits.modules = modules;
  traits.min_log_level = 3;
  api->setup(&traits);
  api->initialize(&traits);
  if (api->start_maintenance(True)) api->join_maintenance_thread();
  RimeSessionId s = api->create_session();
  if (!api->select_schema(s, argv[3])) { fprintf(stderr, "schema %s not selectable\n", argv[3]); return 1; }
  api->set_option(s, "ascii_mode", False);

  FILE *in = fopen(argv[4], "r");
  if (!in) { perror(argv[4]); return 1; }
  char line[1024];
  size_t n = 0, cap = 1 << 16;
  double *keys = malloc(cap * sizeof *keys);
  while (fgets(line, sizeof line, in)) {
    char *want = strchr(line, '\t');
    if (!want) continue;
    *want++ = 0;
    want[strcspn(want, "\n")] = 0;
    api->clear_composition(s);
    for (const char *k = line; *k; ++k) {
      double t = now_us();
      api->process_key(s, *k, 0);
      RIME_STRUCT(RimeContext, kc);
      if (api->get_context(s, &kc)) api->free_context(&kc);
      if (n < cap) keys[n++] = now_us() - t;
    }
    int rank = -1;
    RIME_STRUCT(RimeContext, ctx);
    if (api->get_context(s, &ctx)) {
      for (int i = 0; i < ctx.menu.num_candidates && rank < 0; ++i)
        if (!strcmp(ctx.menu.candidates[i].text, want)) rank = i;
      api->free_context(&ctx);
    }
    printf("%d\t%s\t%s\n", rank, line, want);
  }
  qsort(keys, n, sizeof *keys, cmp);
  long rss = 0;
  FILE *st = fopen("/proc/self/status", "r");
  while (st && fgets(line, sizeof line, st))
    if (!strncmp(line, "VmHWM:", 6)) rss = atol(line + 6);
  if (st) fclose(st);
  fprintf(stderr, "key_p50_us=%.0f key_p95_us=%.0f rss_kb=%ld\n", n ? keys[n / 2] : 0, n ? keys[n * 95 / 100] : 0, rss);
  api->destroy_session(s);
  api->finalize();
  return 0;
}
