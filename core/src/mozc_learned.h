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

// Picks with a time no clock could have given are taken in from no device's record, nor learned from this one's,
// until their time is possible: before 2020, or more than a day ahead of now. Mozc keeps times unsigned, so one
// before 1970 would rank in 2106. They stay in the records, so they come in once the clocks catch up.
inline constexpr int64_t kEarliest = 1577836800;  // 2020-01-01
inline constexpr int64_t kAhead = 24 * 60 * 60;

// (reading, written) → when it was last picked, in seconds since 1970. Each line of the record is
// reading<TAB>written<TAB>time.
using Record = std::map<std::pair<std::string, std::string>, int64_t>;

Record parse(std::string_view text);
// Another device's record as taken in: empty past kMaxBytes, else its kMost most recent picks with a possible time.
Record accept(std::string_view text, int64_t now);
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

// When Japanese was last forgotten here, kept in mozc_learned.forgotten: this device's time then, and for each
// other device, the latest pick its record held then, by that device's own clock, so a clock set differently
// doesn't decide what was before the Forget. Its first line is `here`, then a line device<TAB>latest each.
struct Forgotten {
  int64_t here = 0;  // 0: never
  std::map<std::string, int64_t> devices;
  bool operator==(const Forgotten &) const = default;
};
Forgotten parseForgotten(std::string_view text);
std::string format(const Forgotten &forgotten);
// The latest pick in a record, 0 when it is empty. For Forget, by every pick's time, possible or not: that
// device's clock may be ahead of this one's.
int64_t latest(const Record &record);

struct Pick {
  std::string key, value;
  int64_t time;  // when Mozc learns it as picked: its order among the others' (toLearn)
  bool operator==(const Pick &) const = default;
};
struct Other {
  Record record, learned;  // another device's record, and the copy of it last learned
  int64_t forgotten = 0;   // its latest pick when Japanese was last forgotten here (Forgotten::devices), 0: none
};
// What Mozc learns, in order, from every other device's record: for each reading another device picked something
// for since its copy last learned, every pick known for it on any device (this one's too), oldest first, so the
// latest pick is learned last and comes first. Picks made at the same second go by the written form, so every
// device ends with the same order. Picks from before Japanese was last forgotten here are left out everywhere:
// this device's at or before `forgotten`, another's at or before its Other::forgotten. Forgotten stays forgotten
// (Decisions #2, 2026-11-19) until picked again. Mozc ranks what it learned by when, in seconds, so each is learned
// at its own time, but never after now, each after the one before it, and of one reading, far enough after that
// it also comes first in Mozc's prediction, which takes a second off per character of the written form.
std::vector<Pick> toLearn(const Record &own, int64_t forgotten, const std::vector<Other> &others, int64_t now);

}  // namespace sebtype::learned
