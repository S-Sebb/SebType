// SebType core: Mozc's learned conversions' record (mozc_learned.h, #409). MIT, SebType.
#include "mozc_learned.h"

#include <algorithm>
#include <charconv>
#include <set>
#include <tuple>

namespace sebtype::learned {

Record parse(std::string_view text) {
  Record record;
  if (!text.starts_with(kHeader)) return record;
  text.remove_prefix(kHeader.size());
  // A last line without its newline was cut short (a write the sync read halfway): left out.
  for (size_t end; (end = text.find('\n')) != std::string_view::npos; text.remove_prefix(end + 1)) {
    const std::string_view line = text.substr(0, end);
    const size_t a = line.find('\t'), b = a == line.npos ? a : line.find('\t', a + 1);
    if (b == line.npos || a == 0 || b == a + 1 || line.find('\t', b + 1) != line.npos) continue;
    const std::string_view when = line.substr(b + 1);
    int64_t time = 0;
    const auto [at, error] = std::from_chars(when.data(), when.data() + when.size(), time);
    if (error != std::errc() || at != when.data() + when.size() || when.empty()) continue;
    add(record, std::string(line.substr(0, a)), std::string(line.substr(a + 1, b - a - 1)), time);
  }
  return record;
}

namespace {
// (time, written, reading): oldest first, then by the written form.
using Ordered = std::tuple<int64_t, const std::string *, const std::string *>;
bool earlier(const Ordered &x, const Ordered &y) {
  return std::get<0>(x) != std::get<0>(y)   ? std::get<0>(x) < std::get<0>(y)
         : *std::get<1>(x) != *std::get<1>(y) ? *std::get<1>(x) < *std::get<1>(y)
                                              : *std::get<2>(x) < *std::get<2>(y);
}
}  // namespace

std::string format(const Record &record) {
  std::vector<Ordered> picks;
  for (const auto &[pick, time] : record) picks.emplace_back(time, &pick.second, &pick.first);
  std::sort(picks.begin(), picks.end(), earlier);
  const size_t from = picks.size() > kMost ? picks.size() - kMost : 0;
  std::string text(kHeader);
  for (size_t i = from; i < picks.size(); ++i) {
    const auto &[time, value, key] = picks[i];
    text.append(*key).append("\t").append(*value).append("\t").append(std::to_string(time)).append("\n");
  }
  return text;
}

void add(Record &record, const std::string &key, const std::string &value, int64_t time) {
  auto [it, added] = record.try_emplace({key, value}, time);
  if (!added) it->second = std::max(it->second, time);
}

std::vector<Pick> toLearn(const Record &own, const std::vector<std::pair<Record, Record>> &others, int64_t now) {
  Record all = own;
  std::set<std::string> fresh;
  for (const auto &[now, learned] : others) {
    for (const auto &[pick, time] : now) {
      add(all, pick.first, pick.second, time);
      const auto it = learned.find(pick);
      if (it == learned.end() || it->second < time) fresh.insert(pick.first);
    }
  }
  std::vector<Ordered> picks;
  for (const auto &[pick, time] : all) {
    if (fresh.contains(pick.first)) picks.emplace_back(time, &pick.second, &pick.first);
  }
  std::sort(picks.begin(), picks.end(), earlier);
  std::vector<Pick> out;
  for (const auto &[time, value, key] : picks) {
    const int64_t at = std::min(time, now);
    out.push_back({*key, *value, out.empty() ? at : std::max(at, out.back().time + 1)});
  }
  return out;
}

}  // namespace sebtype::learned
