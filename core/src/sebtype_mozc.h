// SebType core: the C interface of a Mozc built into a library, so core/ runs Mozc's session handler in its own
// process (mozc_inprocess.cpp, #220). The phone's libmozc.so (engines/mozc/src/android/jni) exports it today;
// the PCs' build of the same interface follows in #233. A C interface keeps Mozc's own protobuf and Abseil
// inside the library. MIT, SebType.
#pragma once

#include <cstddef>
#include <cstdint>

extern "C" {

// Loads Mozc's engine with its profile (learned words, user dictionaries) in profile_dir and its dictionary
// from data_file, the region [offset, offset + length) of it (length 0: the whole file). An empty data_file:
// the library's own data. Loading again replaces the engine. Nonzero when it loaded.
int sebtype_mozc_open(const char *profile_dir, const char *data_file, int64_t offset, int64_t length);
// One serialized mozc.commands.Input in, its serialized Output in *out (freed with sebtype_mozc_free).
// Nonzero when Mozc answered.
int sebtype_mozc_eval(const char *in, size_t in_size, char **out, size_t *out_size);
void sebtype_mozc_free(char *bytes);
// Saves learned words and frees the engine until the next open.
void sebtype_mozc_close();
// A user dictionary file in any format Mozc imports (Mozc, MS-IME, ATOK, Kotoeri text) as a serialized
// mozc.user_dictionary.UserDictionary in *out; entries it can't read are skipped.
int sebtype_mozc_import_user_dictionary(const char *text, size_t size, char **out, size_t *out_size);

}  // extern "C"
