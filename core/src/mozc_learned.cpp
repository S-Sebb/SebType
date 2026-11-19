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

std::vector<Ordered> ordered(const Record &record) {
  std::vector<Ordered> picks;
  for (const auto &[pick, time] : record) picks.emplace_back(time, &pick.second, &pick.first);
  std::sort(picks.begin(), picks.end(), earlier);
  return picks;
}

std::string lines(const std::vector<Ordered> &picks, size_t from) {
  std::string text;
  for (size_t i = from; i < picks.size(); ++i) {
    const auto &[time, value, key] = picks[i];
    text.append(*key).append("\t").append(*value).append("\t").append(std::to_string(time)).append("\n");
  }
  return text;
}

// Characters, as Mozc's prediction counts them (Util::CharsLen): UTF-8 lead bytes.
int64_t chars(const std::string &s) {
  return std::count_if(s.begin(), s.end(), [](char c) { return (static_cast<unsigned char>(c) & 0xC0) != 0x80; });
}
}  // namespace

std::string format(const Record &record, size_t most) {
  const std::vector<Ordered> picks = ordered(record);
  return std::string(kHeader) + lines(picks, picks.size() > most ? picks.size() - most : 0);
}

Record accept(std::string_view text, int64_t now) {
  if (text.size() > kMaxBytes) return {};
  Record record = parse(text);
  std::erase_if(record, [now](const auto &pick) { return pick.second < kEarliest || pick.second > now + kAhead; });
  return record.size() <= kMost ? record : parse(format(record));
}

Recorded record(std::string_view file, const Record &picks) {
  const size_t count = static_cast<size_t>(std::count(file.begin(), file.end(), '\n'));  // with the header's
  if (file.starts_with(kHeader) && count - 1 + picks.size() <= kMost) return {lines(ordered(picks), 0), false};
  Record whole = parse(file);
  for (const auto &[pick, time] : picks) add(whole, pick.first, pick.second, time);
  // Grown past kMost: cut back further, so the next picks append for a while again.
  return {format(whole, file.starts_with(kHeader) ? kKeep : kMost), true};
}

void add(Record &record, const std::string &key, const std::string &value, int64_t time) {
  auto [it, added] = record.try_emplace({key, value}, time);
  if (!added) it->second = std::max(it->second, time);
}

Forgotten parseForgotten(std::string_view text) {
  Forgotten f;
  auto number = [](std::string_view s, int64_t &n) {
    const auto [at, error] = std::from_chars(s.data(), s.data() + s.size(), n);
    return error == std::errc() && at == s.data() + s.size() && !s.empty();
  };
  for (bool first = true; !text.empty(); first = false) {
    size_t end = text.find('\n');
    const std::string_view line = text.substr(0, end);
    text.remove_prefix(end == text.npos ? text.size() : end + 1);
    const size_t tab = line.find('\t');
    int64_t time = 0;
    if (first) {
      if (number(line, time)) f.here = time;
    } else if (tab != line.npos && tab > 0 && number(line.substr(tab + 1), time)) {
      f.devices[std::string(line.substr(0, tab))] = time;
    }
  }
  return f;
}

std::string format(const Forgotten &forgotten) {
  std::string text = std::to_string(forgotten.here) + "\n";
  for (const auto &[device, time] : forgotten.devices) text += device + "\t" + std::to_string(time) + "\n";
  return text;
}

int64_t latest(const Record &record) {
  int64_t time = 0;
  for (const auto &[pick, t] : record) time = std::max(time, t);
  return time;
}

std::vector<Pick> toLearn(const Record &own, int64_t forgotten, const std::vector<Other> &others, int64_t now) {
  Record all;
  std::set<std::string> fresh;
  for (const auto &[pick, time] : own) {
    if (time > forgotten && time >= kEarliest && time <= now + kAhead) add(all, pick.first, pick.second, time);
  }
  for (const Other &other : others) {
    for (const auto &[pick, time] : other.record) {
      if (time <= other.forgotten) continue;
      const Record &learned = other.learned;
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
  std::vector<Pick> out(picks.size());
  // From the latest back: each at its own time, but before the one after it and never after now. Of one reading,
  // the later one's prediction score (time less its characters) stays higher too.
  std::map<std::string, std::pair<int64_t, int64_t>> after;  // reading → the later pick's (time, characters)
  int64_t next = now + 1;
  for (size_t i = picks.size(); i-- > 0;) {
    const auto &[time, value, key] = picks[i];
    const int64_t length = chars(*value);
    next = std::min(time, next - 1);
    if (const auto it = after.find(*key); it != after.end()) {
      next = std::min(next, it->second.first - 1 - std::max<int64_t>(0, it->second.second - length));
    }
    after[*key] = {next, length};
    out[i] = {*key, *value, next};
  }
  // Spaced back past kEarliest: all moved forward together, so the order stays, and never past now.
  if (!out.empty() && out.front().time < kEarliest) {
    const int64_t by = std::min(kEarliest - out.front().time, now - out.back().time);
    for (Pick &p : out) p.time += by;
  }
  return out;
}

}  // namespace sebtype::learned
