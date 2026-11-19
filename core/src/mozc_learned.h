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

// (reading, written) → when it was last picked, in seconds since 1970. Each line of the record is
// reading<TAB>written<TAB>time.
using Record = std::map<std::pair<std::string, std::string>, int64_t>;

Record parse(std::string_view text);
// kHeader and the kMost most recent picks, oldest first: the same record always makes the same text.
std::string format(const Record &record);
// A pick, keeping the later time of one already there.
void add(Record &record, const std::string &key, const std::string &value, int64_t time);

struct Pick {
  std::string key, value;
  int64_t time;  // when Mozc learns it as picked: its order among the others' (toLearn)
  bool operator==(const Pick &) const = default;
};
// What Mozc learns, in order, from the other devices' records, each with the copy of it last learned: for each
// reading another device picked something for since, every pick known for it (this device's own too), oldest
// first, so the latest pick is learned last and comes first. Picks made at the same second go by the written form,
// so every device ends with the same order. Mozc ranks what it learned by when, in seconds, so each is learned at
// its own time (no later than now) and a second after the one before it: as picked here, against this device's
// own picks too.
std::vector<Pick> toLearn(const Record &own, const std::vector<std::pair<Record, Record>> &others, int64_t now);

}  // namespace sebtype::learned
