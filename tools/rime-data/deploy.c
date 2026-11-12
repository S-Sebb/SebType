// Compiles a Rime shared dir into USER/build, the way the keyboard's own first deploy would, then
// types SELF_TEST (with OPTION on, if given) and prints the first candidate. build.sh moves the result
// into the shared dir. SELF_TEST "^`" (Ctrl+`) or "F4" presses that key instead and prints whether
// Rime took it.
//   deploy SHARED USER SCHEMA SELF_TEST [OPTION]   prints "librime=<version>" and "first=<candidate>"
//                                                  or "handled=<0|1>"
#include <string.h>
#include <stdio.h>
#include "rime_api.h"

int main(int argc, char **argv) {
  if (argc != 5 && argc != 6) { fprintf(stderr, "usage: deploy SHARED USER SCHEMA SELF_TEST [OPTION]\n"); return 2; }
  RimeApi *api = rime_get_api();
  RIME_STRUCT(RimeTraits, traits);
  traits.shared_data_dir = argv[1];
  traits.user_data_dir = argv[2];
  traits.app_name = "rime.sebtype-build";
  traits.min_log_level = 1; // warnings and errors, to stderr
  api->setup(&traits);
  api->initialize(&traits);
  if (api->start_maintenance(True)) api->join_maintenance_thread();
  printf("librime=%s\n", api->get_version());

  RimeSessionId s = api->create_session();
  if (!api->select_schema(s, argv[3])) { fprintf(stderr, "schema %s not selectable\n", argv[3]); return 1; }
  api->set_option(s, "ascii_mode", False);
  if (argc == 6) api->set_option(s, argv[5], True);
  int key = !strcmp(argv[4], "^`") ? '`' : !strcmp(argv[4], "F4") ? 0xffc1 : 0;
  if (key) {
    printf("handled=%d\n", api->process_key(s, key, key == '`' ? 1 << 2 : 0)); // Control+grave, F4
    api->destroy_session(s);
    api->finalize();
    return 0;
  }
  for (const char *k = argv[4]; *k; ++k) api->process_key(s, *k, 0);
  RIME_STRUCT(RimeContext, ctx);
  if (api->get_context(s, &ctx)) {
    if (ctx.menu.num_candidates > 0) printf("first=%s\n", ctx.menu.candidates[0].text);
    api->free_context(&ctx);
  }
  api->destroy_session(s);
  api->finalize();
  return 0;
}
