// SebType core: Mozc's learned conversions as a record the sync carries between the user's devices (#409): which
// written form the user picked for a reading, over Mozc's first candidate. Mozc's own files (segment.db, the
// history) keep only hashes and its own layout, so each device keeps this record of its picks beside them, and
// learns the other devices' picks into its Mozc (mozc_inprocess.cpp). MIT, SebType.
#pragma once

#include <cstddef>
#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace sebtype::learned {

// The record's first line; a record of another version is read as empty, never misread.
inline constexpr std::string_view kHeader = "# SebType mozc_learned 1\n";
// The most a device's record keeps, its most recent picks: about 40 bytes each.
inline constexpr size_t kMost = 5000;
// What a record grown to kMost is cut back to, so the next picks append for a while before it is rewritten.
inline constexpr size_t kKeep = kMost - kMost / 10;
// A larger record from another device isn't read at all (accept): kMost picks of long readings fit well within.
inline constexpr size_t kMaxBytes = 1 << 20;

// (reading, written) → when it was last picked, in seconds since 1970. Each line of the record is
// reading<TAB>written<TAB>time.
using Record = std::map<std::pair<std::string, std::string>, int64_t>;

Record parse(std::string_view text);
// Another device's record as taken in: empty past kMaxBytes, else its kMost most recent picks.
Record accept(std::string_view text);
// kHeader and the `most` most recent picks, oldest first: the same record always makes the same text.
std::string format(const Record &record, size_t most = kMost);
// A pick, keeping the later time of one already there.
void add(Record &record, const std::string &key, const std::string &value, int64_t time);

// What recording new picks does to this device's record file: appends `text`, or when the file is new or its
// lines would pass kMost, rewrites it whole as `text`, cut to its kKeep most recent. Never past kMost lines.
struct Recorded {
  std::string text;
  bool whole;
};
Recorded record(std::string_view file, const Record &picks);

struct Pick {
  std::string key, value;
  int64_t time;  // when Mozc learns it as picked: its order among the others' (toLearn)
  bool operator==(const Pick &) const = default;
};
// What Mozc learns, in order, from every other device's record, each with the copy of it last learned: for each
// reading another device picked something for since, every pick known for it on any device (this one's too),
// oldest first, so the latest pick is learned last and comes first. Picks made at the same second go by the written
// form, so every device ends with the same order. Picks at or before `forgotten`, when Japanese was last
// forgotten here (0: never), are left out everywhere: forgotten stays forgotten (Decisions #2, 2026-11-19) until
// picked again. Mozc ranks what it learned by when, in seconds, so each is learned at its own time, but never
// after now and each a second after the one before it, counting back from now where needed.
std::vector<Pick> toLearn(const Record &own, const std::vector<std::pair<Record, Record>> &others, int64_t forgotten,
                          int64_t now);

}  // namespace sebtype::learned
