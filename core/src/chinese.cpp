// SebType core: SebType's Chinese model (engines/sebtype-lm/zh_lm, tools/chinese-lm) around 中文's Rime engine
// (#264, the experiment of #259: docs/experiments/2026-11-16-chinese-lm.md). MIT, SebType.
//
// Threads: keys go to Rime on the caller's thread (the phone's engine thread). The model loads on a worker
// thread when the engine starts, and after each change reranks Rime's first candidates, adds its own and,
// with nothing typed, predicts the next words there, as English's model does. Until its list comes, the
// list shown stays, so a key changes it once (#450); Rime's shows at once while the model takes longer.
// The worker announces its list through READY; the frontend reads it with candidates(). Each list carries the
// revision it was asked for, which every change (a key, a pick, the field's text, the settings) moves on,
// so a list that comes late never shows.
//
// What the model reads: the field's text before the composition and Rime's input, while no part of it is
// chosen (after a partial pick Rime alone lists the rest). It scores Rime's candidates that cover the whole
// input, by their characters against Rime's syllables, and leaves the others in Rime's order after its own.
// The model's own candidates that read the letters otherwise than Rime does (n as ng, a whole syllable as one
// cut short: 当 for dan, #503) go after Rime's first two pages' candidates for the whole input when Rime's
// first is a dictionary word for all of it (但 for dan): the model was trained to accept those slips, which
// fuzzy pinyin off rules out ahead of a word typed as it is. Behind a sentence Rime pieced together (其则么早
// for qizemezao) they keep their place, where they are mostly typo fixes. Rime's syllables decide, by the
// characters' readings in rime-data's sebtype_readings.txt (8105's).
// The model's own candidates that don't spell the letters typed, but for two typos, are dropped (#563): its
// beam may end early (it ends at <E> whenever that is likelier than going on, and trained on spans of at most
// 14 characters it often is on longer input), drop a syllable (我的圣诞快乐 for wodeshengdanbukuaile) or loop
// (胖胖胖… for a clause), and plain() favours a short text, as each character costs log probability. Picking
// one commits it for all the letters typed, so 庞庞 for a clause of 20 syllables loses the rest of the clause.
// Edits are counted against the characters' readings, not Rime's syllables: Rime splits a misspelled syllable
// (xiagn as xia g n), and the model's 想 for it is right. Fuzzy pinyin (z for zh, n for ng) costs none: its
// users type it in every syllable, and the model reads it. Rime's typo corrections (below) that don't spell the
// letters so stay where Rime has them.
// Picking one of Rime's candidates selects it in Rime by its own index. Picking one of the model's puts it
// into Rime's user dictionary under the syllables typed when Rime reads them all as whole ones (#518), so it
// is learned, synced and forgotten as Rime's own picks are, and comes first the next time as they do:
// 猫狗就要 for maogoujiya too, where the model reads jiya as 就要 and Rime has no pieces for it. Selecting
// pieces that spell it didn't do that: on the phone Rime's menu holds typo corrections (就 for ji), which
// Rime learns nothing from. Initials (w m for 我没) have no syllables to store under: there it teaches Rime by
// selecting the pieces that spell it.
// 繁: Rime converts its own candidates (rime-ice's traditionalization); the model reads simplified text, so
// OpenCC's t2s turns Rime's candidates and the field's text into it, and s2t the model's into 繁.
//
// Typos that read as valid pinyin (#478: yuelaiyuxiao, 越来越小 meant): once the model's list for the input
// has shown, the worker asks READY again, and on that turn of the caller's thread Rime reads the input with
// typo corrections in a session of its own (Engine::corrections). The model scores those on the worker, and
// the list changes once more: the correction first when the model is about as sure of it as of the list's
// first, else on the first page when nearly as sure. Keys never wait for either.
#include <sebtype/hosts.h>

#include <opencc.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <optional>
#include <set>
#include <string_view>
#include <thread>
#include <unordered_map>
#include <utility>

#include "trace.h"
#include "zh_lm.h"

namespace sebtype {
namespace {

// The experiment's tuned stack (#259, tune.py on the dev sets): the model scores Rime's first 4, adds a beam
// of 2 of its own, and ranks by its log probability less 0.5 · ln(1 + Rime's rank), its own counting as rank 4.
constexpr int kScored = 4, kBeam = 2;
constexpr float kRankWeight = 0.5f, kOwnRank = 4;
// With no Chinese text before the cursor the model knows no more than Rime's dictionary, which it otherwise
// overrules for words typed alone (按住 → 安卓, #482): there Rime's order weighs 2 · ln(1 + rank) and the
// model's own candidates 3 more. Tuned on dev sets typed with nothing before them (words, clauses, typos).
constexpr float kAloneRankWeight = 2, kAloneOwnPenalty = 3;
// The first kPlain by that score are then re-ordered with part of their log probability as plain text after
// the context (zh_lm plain()) added, so that a text that fits the letters only by a wrong first character
// (剪个深 for jiangeshen) loses there (#502): 0.4 of it for Rime's candidates and 0.5 for the model's own, which
// no dictionary vouches for. Tuned on the dev sets; re-ordering more than the first 3 gained nothing there,
// cost first places and top-3 places, and takes longer.
constexpr size_t kPlain = 3;
constexpr float kPlainWeight = 0.4f, kOwnPlainWeight = 0.5f;
constexpr size_t kNextWords = 5;
// The edits (Readings::edits) a candidate may be from the letters typed: two typos, the most a test item has
// (#563). A left-out syllable of two letters or more costs 3, or 2 where a letter typed as spelled parts its own.
constexpr int kTypos = 2;
constexpr size_t kContextBytes = 1000;  // the field's text before the cursor kept; the model reads 64 characters
constexpr int kTeachCandidates = 60;    // Rime's candidates searched for each piece of a model's candidate
// How long the list shown waits for the model's after a change, so a key changes it once (#450): the phone's
// rankings and next words take 14-107 ms at p95, by its cores (docs/perf/2026-11-19-chinese-model.md).
constexpr std::chrono::milliseconds kHold{100};
// Phrase-level correction (#478): how far (log probability) Rime's best correction may trail the list's first
// and still go first, or go last on the first page. Tuned on the slip set with the clean sets as the guard
// (android/test/chinese-lm/tune_fix.py, with #482's weights for text typed alone): the model's own beam already
// finds most of what it is surer of, and trailing by more than 0.5 cost the partial-pinyin and abbreviation sets
// their first places; weighing Rime's next corrections too gained nothing. The correction counts as Rime's 5th
// candidate, also alone: it is Rime's reading, where the beam's guesses get kAloneOwnPenalty. The model weighs it
// once typing pauses for kFixPause.
constexpr float kFixLead = 0.5f, kFixFloor = 4;
constexpr std::chrono::milliseconds kFixPause{300};
namespace ks {
constexpr uint32_t space = 0x20, BackSpace = 0xff08, Up = 0xff52, Down = 0xff54, Page_Up = 0xff55, Page_Down = 0xff56;
}

bool han(char32_t c) { return (c >= 0x3400 && c <= 0x4dbf) || (c >= 0x4e00 && c <= 0x9fff) || (c >= 0x20000 && c <= 0x3134f); }

std::vector<char32_t> codePoints(const std::string &s) {
  std::vector<char32_t> out;
  for (size_t i = 0; i < s.size();) {
    const unsigned char c = s[i];
    const int n = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : 4;
    char32_t cp = n == 1 ? c : n == 2 ? c & 0x1f : n == 3 ? c & 0x0f : c & 0x07;
    for (int k = 1; k < n && i + k < s.size(); k++) cp = cp << 6 | (s[i + k] & 0x3f);
    out.push_back(cp);
    i += n;
  }
  return out;
}

// The number of syllables in Rime's preedit for its input, as it shows them: "ni hao ma", "z d", "xi'an".
size_t syllables(const std::string &preedit) {
  size_t n = 0;
  bool in = false;
  for (char c : preedit) {
    const bool letter = (c >= 'a' && c <= 'z') || static_cast<unsigned char>(c) >= 0x80;
    if (letter && !in) n++;
    in = letter;
  }
  return n;
}

// Rime's preedit's syllables: "ni hao ma" → ni, hao, ma; "xi'an" → xi, an; ü as v, as the readings spell it.
std::vector<std::string> syllableList(const std::string &preedit) {
  std::vector<std::string> out;
  std::string cur;
  for (size_t i = 0; i <= preedit.size(); i++) {
    if (i < preedit.size() && preedit.compare(i, 2, "ü") == 0) {
      cur += 'v', i++;
    } else if (i < preedit.size() && preedit[i] >= 'a' && preedit[i] <= 'z') {
      cur += preedit[i];
    } else if (!cur.empty()) {
      out.push_back(std::move(cur));
      cur.clear();
    }
  }
  return out;
}

// Each Han character's pinyin readings, from rime-data's sebtype_readings.txt ("字<TAB>reading" lines), and
// every syllable among them.
struct Readings {
  std::unordered_map<char32_t, std::vector<std::string>> of;
  std::set<std::string> syllables;

  explicit Readings(const std::string &path) {
    std::ifstream in(std::filesystem::u8path(path));  // UTF-8, as Windows' %APPDATA% may not be ASCII
    if (!in) std::fprintf(stderr, "sebtype: can't read %s\n", path.c_str());
    for (std::string line; std::getline(in, line);) {
      const size_t tab = line.find('\t');
      if (tab == std::string::npos) continue;
      const auto cps = codePoints(line.substr(0, tab));
      if (cps.size() != 1) continue;
      const std::string r = line.substr(tab + 1);
      of[cps[0]].push_back(r);
      syllables.insert(r);
    }
  }

  // Whether TEXT reads as SYLLABLES as Rime reads them: a character per syllable, each with that syllable
  // among its readings, or one starting with it where the syllable is no whole one (an initial, "zho").
  bool spell(const std::string &text, const std::vector<std::string> &syl) const {
    const auto cps = codePoints(text);
    if (cps.size() != syl.size()) return false;
    for (size_t i = 0; i < cps.size(); i++) {
      const auto it = of.find(cps[i]);
      if (it == of.end()) return false;
      const bool whole = syllables.count(syl[i]) > 0;
      if (std::ranges::none_of(it->second, [&](const std::string &r) { return whole ? r == syl[i] : r.starts_with(syl[i]); }))
        return false;
    }
    return true;
  }

  // The fewest edits from the letters TYPED to what TEXT's characters spell, each by one of its readings, that
  // reading confused as fuzzy pinyin's users type it throughout (zh as z, ng as n, either way), or its first
  // letters (zd for 知道, ranh for 然后): a letter typed otherwise or in excess, one missing, or two swapped in
  // a syllable cost 1, but a letter typed otherwise or in excess right after another costs 2. So a syllable
  // left out (bu) costs 3 where its letters are together, also where a reading takes one of its letters (dai
  // for 大 in dadafa), but 2 where a good letter parts them (gnfeng for 能: g and f), and two typos side by side
  // cost 3. A character without readings spells any 1-6 letters. Above kTypos it stops, at kTypos + 1.
  int edits(const std::string &text, const std::string &typed) const {
    const size_t n = typed.size();
    // For each prefix of TYPED, the fewest edits to it from the letters spelled so far, its last letter typed
    // as spelled (in) or otherwise or in excess (off).
    struct Row {
      std::vector<int> in, off;
    };
    const auto blank = [&] { return Row{std::vector<int>(n + 1, 1 << 20), std::vector<int>(n + 1, 1 << 20)}; };
    const auto least = [](const Row &r, size_t j) { return std::min(r.in[j], r.off[j]); };
    const auto off = [](const Row &r, size_t j) { return std::min(r.in[j] + 1, r.off[j] + 2); };  // one more off
    const auto excess = [&](Row &r) {
      for (size_t j = 1; j <= n; j++) r.off[j] = std::min(r.off[j], off(r, j - 1));
    };
    Row at = blank();
    at.in[0] = 0;
    excess(at);
    for (char32_t c : codePoints(text)) {
      Row next = blank();
      const auto it = of.find(c);
      if (it == of.end()) {
        for (size_t j = 0; j < n; j++)
          for (size_t k = j + 1; k <= std::min(n, j + 6); k++) next.in[k] = std::min(next.in[k], least(at, j));
        excess(next);
      } else {
        for (const std::string &r : confusions(it->second)) {
          std::vector<Row> rows{at};  // rows[m]: after the reading's first m letters
          for (size_t m = 0; m < r.size(); m++) {
            Row row = blank();
            const Row &prev = rows[m];
            for (size_t j = 0; j <= n; j++) {
              row.in[j] = prev.in[j] + 1, row.off[j] = prev.off[j] + 1;  // r[m] missing
              if (j && r[m] == typed[j - 1]) row.in[j] = std::min(row.in[j], least(prev, j - 1));
              if (j && r[m] != typed[j - 1]) row.off[j] = std::min(row.off[j], off(prev, j - 1));
              if (m && j >= 2 && r[m] == typed[j - 2] && r[m - 1] == typed[j - 1])
                row.in[j] = std::min(row.in[j], least(rows[m - 1], j - 2) + 1);
            }
            excess(row);
            for (size_t j = 0; j <= n; j++)  // the reading may end here, cut short
              next.in[j] = std::min(next.in[j], row.in[j]), next.off[j] = std::min(next.off[j], row.off[j]);
            rows.push_back(std::move(row));
          }
        }
      }
      at = std::move(next);
      // No edit is taken back: once every prefix costs more, so does the whole.
      if (std::ranges::min(at.in) > kTypos && std::ranges::min(at.off) > kTypos) return kTypos + 1;
    }
    return least(at, n);
  }

  // READINGS and their confusions: zh, ch, sh as z, c, s and n as ng, and the other way (as
  // tools/chinese-lm/common.py's typos make them; ng as n is a reading cut short).
  static std::vector<std::string> confusions(const std::vector<std::string> &readings) {
    std::vector<std::string> out;
    for (const std::string &r : readings) {
      out.push_back(r);
      if (r.size() > 2 && r[1] == 'h' && std::string_view("zcs").find(r[0]) != std::string_view::npos)
        out.push_back(r.substr(0, 1) + r.substr(2));
      else if (r.size() > 1 && std::string_view("zcs").find(r[0]) != std::string_view::npos)
        out.push_back(r.substr(0, 1) + 'h' + r.substr(1));
      if (r.ends_with("an") || r.ends_with("en") || r.ends_with("in")) out.push_back(r + 'g');
    }
    return out;
  }
};

// A candidate the model can score: Han characters only, one per syllable of the whole input. Partial ones
// (你好 for nihaoma), Rime's English words, emoji and the clock aren't.
bool wholeInput(const std::string &text, size_t syllableCount) {
  const auto cps = codePoints(text);
  return cps.size() == syllableCount && std::ranges::all_of(cps, han);
}

// OpenCC's conversion with one of its configs, opened when first needed; text as it is when it can't open.
class Converter {
 public:
  explicit Converter(std::string config) : config_(std::move(config)) {}
  ~Converter() {
    if (handle_ != opencc_t(-1) && handle_) opencc_close(handle_);
  }
  std::string operator()(const std::string &text) {
    if (!handle_) {
      handle_ = opencc_open(config_.c_str());
      if (handle_ == opencc_t(-1)) std::fprintf(stderr, "sebtype: can't open OpenCC's %s\n", config_.c_str());
    }
    if (handle_ == opencc_t(-1) || text.empty()) return text;
    char *out = opencc_convert_utf8(handle_, text.c_str(), text.size());
    if (!out) return text;
    std::string s(out);
    opencc_convert_utf8_free(out);
    return s;
  }

 private:
  std::string config_;
  opencc_t handle_ = nullptr;
};

class Chinese final : public Engine {
 public:
  Chinese(std::unique_ptr<Engine> rime, const ChineseModelPaths &paths, std::function<void()> ready)
      : rime_(std::move(rime)), paths_(paths), ready_(std::move(ready)) {
    worker_ = std::thread([this] { work(); });
  }

  // A ranking in flight stops at its next step and is dropped: no ready() comes once the engine stops.
  ~Chinese() override {
    {
      std::lock_guard g(mutex_);
      stop_ = true;
      revNow_ = ~uint64_t{0};
    }
    wake_.notify_all();
    worker_.join();
  }

  bool key(const Key &k) override {
    if (!k.release && !(k.mods & (mod::Ctrl | mod::Alt | mod::Super)) && rime_->composing() && modelShown_) {
      // What Rime would commit or highlight is in its own order: the model's list picks and highlights in
      // its own instead. Paging keys are rime-ice's: Page Up/Down and - =.
      const int size = std::max(rime_->pageSize(), 1), start = highlight_ / size * size;
      const int digit = static_cast<int>(k.sym) - '1';
      Candidate c;
      if (k.sym == ks::space) {
        pick(highlight_);
        return true;
      }
      // A digit past the last page's end picks nothing: Rime's own page isn't the one showing.
      if (digit >= 0 && digit < size) {
        if (candidateAt(start + digit, c)) pick(start + digit);
        return true;
      }
      if (k.sym == ks::Up || k.sym == ks::Down) {
        highlightAt(highlight_ + (k.sym == ks::Up ? -1 : 1));
        return true;
      }
      if (k.sym == ks::Page_Up || k.sym == ks::Page_Down || k.sym == '-' || k.sym == '=') {
        changePage(k.sym == ks::Page_Down || k.sym == '=');
        return true;
      }
      if (commitsFirst(k.sym)) pick(highlight_);
    }
    const bool composing = rime_->composing(), taken = rime_->key(k);
    if (!k.release && !taken && !composing && !paths_.fieldText && (k.sym < 0xffe1 || k.sym > 0xffee)) {
      if (k.sym >= 0x20 && k.sym < 0x7f && !(k.mods & (mod::Ctrl | mod::Alt | mod::Super))) remember(std::string(1, char(k.sym)));
      else context_.clear();
    }
    if (!k.release) changed();
    return taken;
  }

  std::string takeCommit() override {
    collect();
    return std::exchange(commit_, {});
  }

  Preedit preedit() override { return rime_->preedit(); }
  std::string aux() override { return rime_->aux(); }
  bool composing() override { return rime_->composing(); }
  std::string unfinished() override { return rime_->unfinished(); }
  // What the strip highlights is what a flush commits (a field change, the keyboard hidden): the model's
  // candidate, taught to Rime as a pick would be; Rime's own preview when the model's list isn't shown. A
  // Rime candidate for part of the input leaves the rest, which Rime's flush commits after it: nothing stays
  // composing.
  void flush() override {
    if (rime_->composing() && modelShown_ && shownRev_ == rev_ && !shown_.empty()) pick(highlight_);
    rime_->flush();
    changed();
  }
  void flushInput() override {
    rime_->flushInput();
    changed();
  }
  void clear() override {
    rime_->clear();
    if (!paths_.fieldText) context_.clear();
    changed();
  }

  int pageSize() override { return rime_->pageSize(); }
  bool candidateAt(int index, Candidate &out) override {
    if (index < 0) return false;
    // The turn for Rime's corrections (#478) is a list made again: the PCs' hosts read the box only through here.
    if (static_cast<int>(shown_.size()) <= index || shownRev_ != rev_ || shownResult_ != results_ ||
        (fixDue_ == rev_ && fixAsked_ != rev_))
      list(index + 1 + std::max(rime_->pageSize(), 1));
    if (index >= static_cast<int>(shown_.size())) return false;
    out = shown_[index].candidate;
    return true;
  }
  int highlighted() override {
    if (modelShown_ && rime_->composing()) return highlight_;  // what a space picks
    const int h = rime_->highlighted();
    for (size_t i = 0; i < shown_.size(); i++)
      if (shown_[i].rime == h) return static_cast<int>(i);
    return h;
  }
  // The self-test checks the data Rime deployed, so it reads Rime's list, which shows at once: this one keeps
  // the list shown until the model's comes (#450), and would read the list from before (#467).
  std::vector<Candidate> tryTyping(const std::string &text, int max, Field field) override {
    auto list = rime_->tryTyping(text, max, field);
    changed();
    return list;
  }
  void selectAt(int index) override { pick(index); }
  // In the model's list the highlight moves within it; Rime's own highlight stays on its first.
  void highlightAt(int index) override {
    if (modelShown_ && rime_->composing()) {
      if (Candidate c; candidateAt(index, c)) highlight_ = index;
      return;
    }
    rime_->highlightAt(index);
    changed();
  }
  std::string label(int indexOnPage) override { return rime_->label(indexOnPage); }

  bool latin() override { return rime_->latin(); }
  void setLatin(bool on) override {
    rime_->setLatin(on);
    changed();
  }
  bool shiftTapSwitches(uint32_t sym) override { return rime_->shiftTapSwitches(sym); }
  bool alternate() override { return rime_->alternate(); }
  void setAlternate(bool on) override {
    rime_->setAlternate(on);
    changed();
  }

  std::vector<Candidate> candidates(int max) override {
    list(max);
    std::vector<Candidate> out;
    for (const auto &item : shown_) out.push_back(item.candidate);
    return out;
  }

  // A password field's text never reaches the model, nor stays in its context. Incognito and no-learn fields
  // keep their context, as English does: the model predicts from what is on screen, in memory only, and with
  // learning off teach() selects nothing and Rime learns nothing (its no_learning option).
  void setField(Field field) override {
    rime_->setField(field);
    field_ = field;
    if (field == Field::Password) context_.clear();
    changed();
  }
  void setKeys(Keys keys, bool landscape) override { rime_->setKeys(keys, landscape); }
  void setContext(const std::string &before, const std::string &after, bool selection) override {
    rime_->setContext(before, after, selection);
    context_ = field_ == Field::Password ? std::string{} : before;
    trimContext();
    changed();
  }
  void moveCursor(int chars) override {
    rime_->moveCursor(chars);
    changed();
  }
  bool undo() override { return rime_->undo(); }
  Edit takeEdit() override { return rime_->takeEdit(); }

  void applySettings(const Settings &settings, bool learning) override {
    rime_->applySettings(settings, learning);
    learning_ = learning;
    changed();
  }
  void forget() override { rime_->forget(); }
  std::string forgetError() const override { return rime_->forgetError(); }
  void reload() override { rime_->reload(); }
  void deploy() override {
    rime_->deploy();
    changed();
  }
  void save() override { rime_->save(); }
  bool busy() override { return rime_->busy(); }
  bool available() override { return rime_->available(); }
  bool updating() override {
    std::lock_guard g(mutex_);
    if (askedRev_ == rev_ && resultRev_ != rev_ && (loading_ || model_)) return true;
    return fixDue_ == rev_ && fixDone_ != rev_;  // Rime's corrections are still to be weighed (#478)
  }
  std::string input() override { return rime_->input(); }

 private:
  struct Item {
    Candidate candidate;
    int rime = -1;           // Rime's index; -1: the model's own
    std::string simplified;  // the model's own: its text as the model wrote it
    bool misread = false;    // the model's own, reading the letters otherwise than Rime (#503)
    std::string code;        // the model's own: the input's syllables to learn it under ("mao gou ji ya", #518)
  };
  // What the worker is asked for: the model's list for Rime's input (empty: next words) after CONTEXT.
  struct Job {
    uint64_t rev;
    std::string context, input;
    std::vector<std::string> rime;  // Rime's candidates the model scores
    std::vector<int> rimeIndex;     // their indexes in Rime's list
    bool traditional;
    bool fixable = false;           // Rime can correct the input (#478)
    std::string fix;                // Rime's best correction of the input, for the list made already (#478)
    int pageSize = 0;
    std::vector<std::string> syllables;  // Rime's, for the input
    bool word = false;                   // Rime's first is a dictionary word for all of it (#503)
  };

  // Keys Rime takes as "commit the first candidate, then this": printable ASCII but letters, digits, the
  // syllable separator ' and rime-ice's bindings - = [ ] (paging, a candidate's first or last character).
  static bool commitsFirst(uint32_t sym) {
    if (sym < 0x21 || sym > 0x7e) return false;
    const char c = static_cast<char>(sym);
    if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return false;
    return c != '\'' && c != '-' && c != '=' && c != '[' && c != ']';
  }

  // Makes the list shown for the current revision, up to MAX of Rime's: the model's first when it has come,
  // then Rime's others in Rime's order. A candidate of the model's own that Rime has too is Rime's.
  void list(int max) {
    // The model's list for the input has shown, and the worker asked for this turn: Rime's corrections (#478).
    if (modelShown_ && shownRev_ == rev_ && fixDue_ == rev_ && fixAsked_ != rev_) askFixes();
    std::vector<Item> items;
    std::optional<std::vector<Item>> model;
    {
      std::lock_guard g(mutex_);
      shownResult_ = results_;
      if (resultRev_ == rev_) model = result_;
      // Until the model's list comes the one shown stays, while it is expected within kHold: a key changes the
      // list once, not to Rime's and then to the model's (#450).
      else if (askedRev_ == rev_ && model_ && jobTime_ <= kHold) return;
    }
    // Two of Rime's pages (10): about what the phone's bar and its expanded view's first row show, so the
    // common characters of what was typed come first (淡 is Rime's 6th for dan).
    const int misreadAfter = 2 * rime_->pageSize();
    const auto rime = rime_->candidates(std::max(max, misreadAfter));
    std::vector<Item> misread;
    // The model's misreadings (but those Rime lists too: fuzzy pinyin on) come after the last of Rime's first
    // two pages that spells the whole input.
    if (model)
      for (auto &it : *model)
        (it.misread && std::ranges::find(rime, it.candidate.text, &Candidate::text) == rime.end() ? misread : items)
            .push_back(std::move(it));
    int after = -1;
    if (!misread.empty()) {
      const size_t n = syllables(rime_->preedit().text());
      for (int i = 0; i < int(rime.size()) && i < misreadAfter; i++)
        if (wholeInput(rime[i].text, n)) after = i;
    }
    const auto addMisread = [&] {
      for (auto &m : misread) items.push_back(std::move(m));
      misread.clear();
    };
    if (after < 0) addMisread();
    for (size_t i = 0; i < rime.size(); i++) {
      if (std::ranges::none_of(items, [&](const Item &it) { return it.rime == int(i); })) {
        auto same = std::ranges::find_if(items, [&](const Item &it) { return it.rime < 0 && it.candidate.text == rime[i].text; });
        if (same != items.end()) same->rime = int(i), same->candidate.comment = rime[i].comment;
        else items.push_back({rime[i], int(i), {}});
      }
      if (int(i) == after) addMisread();
    }
    // A word the user taught Rime or added under My words, which Rime puts first, stays first: the model can't
    // see what the user picked before (#482), scores only Han text (sebword for qqzz) and Rime's corrections
    // may outscore it (我们 over 我没 learned for wm, #510). An unlearned first is ranked like the others:
    // keeping every first ahead cost most of the model's gain on abbreviations (#369).
    if (model && !rime.empty() && rime[0].learned)
      if (const auto at = std::ranges::find(items, 0, &Item::rime); at != items.end()) std::rotate(items.begin(), at, at + 1);
    shown_ = std::move(items);
    shownRev_ = rev_;
    shownComposing_ = rime_->composing();
    shownInput_ = rime_->input();
    modelShown_ = model.has_value();
    // The harness waits for the corrected list too.
    if (paths_.synchronous && modelShown_ && fixDue_ == rev_ && fixAsked_ != rev_) list(max);
  }

  // The second job for this revision: Rime's corrections of its input, which the model weighs against the
  // list it made.
  void askFixes() {
    fixAsked_ = rev_;
    TraceSection section("SebType zh fixes");
    Job job{rev_, context_, rime_->input(), {}, {}, rime_->alternate()};
    job.pageSize = rime_->pageSize();
    job.syllables = syllableList(rime_->preedit().text());  // to learn a correction picked under (#518)
    for (auto &c : rime_->corrections(job.input, 4))
      if (const auto cps = codePoints(c.text); !cps.empty() && std::ranges::all_of(cps, han)) {
        job.fix = std::move(c.text);
        return want(std::move(job));
      }
    std::lock_guard g(mutex_);
    fixDone_ = rev_;  // none to weigh
  }

  void pick(int index) {
    if (index < 0) return;
    if (index >= static_cast<int>(shown_.size())) {
      // No list shown (a key's own pick): Rime's order
      rime_->selectAt(index);
      changed();
      return;
    }
    Item item = shown_[index];
    // A list kept from before the last change (#450): the word shown, which Rime's menu may have elsewhere
    // or not at all (then it is committed as the model's own are).
    if (shownRev_ != rev_) {
      // Made for what was committed since: it can't replace that, and a tap on it does nothing.
      if (shownComposing_ && !rime_->composing()) return;
      const auto rime = rime_->candidates(kTeachCandidates);
      const auto at = std::ranges::find(rime, item.candidate.text, &Candidate::text);
      item.rime = at == rime.end() ? -1 : int(at - rime.begin());
      // Its syllables are the input's it was made for: kept while that is still the input (the phone's field
      // reports its text after each key, which moves the revision on).
      if (shownInput_ != rime_->input()) item.code.clear();
    }
    // How a pick found the list: "model" (its order) or "rime" (Rime's alone, the model's not come yet or
    // not asked), and whether it picked Rime's candidate or the model's own; "next word" with nothing typed.
    // Both sections cover the pick's work: Rime's selection, teach()'s search piece by piece, the next list.
    TraceSection section("SebType zh pick");
    TraceSection mark(!rime_->composing() ? "next word"
                      : !modelShown_      ? "rime"
                      : item.rime >= 0    ? "model: rime's"
                                          : "model: own");
    if (item.rime >= 0) rime_->selectAt(item.rime);
    else if (rime_->composing()) teach(item);
    else {
      commit_ += item.candidate.text;
      remember(item.candidate.text);
    }
    changed();
  }

  // Commits the model's candidate ITEM and has Rime learn it: under the input's syllables (item.code), or
  // without them by selecting the Rime candidates that spell it, piece by piece from the start of the input,
  // as from the user's own picks. Where Rime has no piece that starts what is left (a typo the model fixed),
  // Rime commits nothing and learns nothing.
  void teach(const Item &item) {
    const std::string &want = item.candidate.text;
    std::string left = want;
    bool taught = false;
    if (learning_ && !item.code.empty()) {
      rime_->learn(item.code, item.simplified);
    } else if (learning_) {
      for (int step = 0; step < 32 && !left.empty() && rime_->composing(); step++) {
        int best = -1;
        size_t bestSize = 0;
        const auto rime = rime_->candidates(kTeachCandidates);
        for (size_t i = 0; i < rime.size(); i++) {
          const auto &t = rime[i].text;
          if (t.size() > bestSize && left.starts_with(t)) best = int(i), bestSize = t.size();
        }
        if (best < 0) break;
        rime_->selectAt(best);
        left.erase(0, bestSize);
        if (!rime_->composing()) taught = left.empty();
      }
    }
    // Rime's own commit (the pieces, converted by Rime) gives way to the text shown.
    rime_->takeCommit();
    if (!taught) rime_->clear();
    commit_ += want;
    remember(want);
  }

  void remember(const std::string &committed) {
    if (committed.empty() || field_ == Field::Password) return;
    context_ += committed;
    trimContext();
  }
  void trimContext() {
    if (context_.size() <= kContextBytes) return;
    size_t cut = context_.size() - kContextBytes;
    while (cut < context_.size() && (context_[cut] & 0xc0) == 0x80) cut++;
    context_.erase(0, cut);
  }

  // Rime's commit, into the commit and the context.
  void collect() {
    const std::string rime = rime_->takeCommit();
    commit_ += rime;
    remember(rime);
  }

  // Something changed: the list shown is Rime's again until the model's for the new revision comes.
  void changed() {
    collect();
    rev_++;
    modelShown_ = false;
    highlight_ = 0;
    Job job{rev_, context_, {}, {}, {}, rime_->alternate()};
    const bool text = field_ == Field::Text && !rime_->latin();
    if (rime_->composing()) {
      const Preedit p = rime_->preedit();
      // Only while nothing is chosen: the first segment is the one being converted, and holds the input.
      const bool whole = !p.segments.empty() && p.segments[0].highlight;
      job.input = rime_->input();
      if (!text || !whole || job.input.empty() || job.input.size() > zh_lm::MAX_LETTERS ||
          !std::ranges::all_of(job.input, [](char c) { return (c >= 'a' && c <= 'z') || c == '\''; }))
        return want(std::nullopt);
      const size_t n = syllables(p.text());
      job.syllables = syllableList(p.text());
      const auto rime = rime_->candidates(kScored);
      for (size_t i = 0; i < rime.size(); i++)
        if (wholeInput(rime[i].text, n)) job.rime.push_back(rime[i].text), job.rimeIndex.push_back(int(i));
      job.word = !rime.empty() && !rime[0].sentence && wholeInput(rime[0].text, n);
      job.fixable = rime_->corrects();
    } else if (!text || !paths_.nextWords || (!context_.empty() && context_.back() == '\n')) {
      return want(std::nullopt);
    }
    want(std::move(job));
  }

  void want(std::optional<Job> job) {
    std::unique_lock l(mutex_);
    const bool asked = job.has_value();
    wanted_ = std::move(job);
    revNow_ = rev_;
    if (!asked) return;
    askedRev_ = rev_;
    const uint64_t before = results_;
    wake_.notify_all();
    if (paths_.synchronous)
      done_.wait(l, [&] { return (resultRev_ == rev_ && results_ != before) || !loading_ && !model_; });
  }

  void work() {
    std::unique_ptr<zh_lm::Model> model;
    Converter s2t(paths_.opencc + "/s2t.json"), t2s(paths_.opencc + "/t2s.json");
    const Readings readings(paths_.readings);
    {
      TraceSection section("SebType zh load");
      try {
        if (!paths_.model.empty()) model = std::make_unique<zh_lm::Model>(paths_.model, paths_.threads);
      } catch (const std::exception &e) {
        std::fprintf(stderr, "sebtype: %s\n", e.what());
      }
    }
    std::unique_lock l(mutex_);
    loading_ = false;
    model_ = model != nullptr;
    done_.notify_all();
    if (!model) return;  // Rime alone
    model->stale = [this] { return revNow_.load() != working_; };
    for (;;) {
      wake_.wait(l, [&] { return stop_ || wanted_; });
      if (stop_) return;
      Job job = std::move(*wanted_);
      wanted_.reset();
      // Corrections weigh against the list made for the same revision, which must have come.
      std::vector<Item> made;
      std::optional<float> first;  // the score of the list's first, which a correction must beat
      if (!job.fix.empty()) {
        // A key meanwhile drops it, so the next key's list never waits behind it.
        if (!paths_.synchronous && wake_.wait_for(l, kFixPause, [&] { return stop_ || wanted_ || revNow_ != job.rev; }))
          continue;
        if (resultRev_ != job.rev || !resultFirst_) {
          fixDone_ = job.rev;
          continue;
        }
        made = result_;
        first = resultFirst_;
      }
      working_ = job.rev;
      const auto start = std::chrono::steady_clock::now();
      l.unlock();
      std::vector<Item> items;
      bool changed = true;
      std::string context = job.traditional ? t2s(job.context) : job.context;
      try {
        if (!job.fix.empty()) {
          TraceSection section("SebType zh fix");
          items = std::move(made);
          changed = fix(*model, readings, job, context, items, *first, s2t);
        } else if (job.input.empty()) {
          TraceSection section("SebType zh next");
          for (const auto &w : model->nextWords(context, kNextWords)) items.push_back(own(w.text, job.traditional, s2t));
        } else {
          TraceSection section("SebType zh rank");
          items = rank(*model, readings, job, context, t2s, s2t, first);
        }
      } catch (const std::exception &e) {
        std::fprintf(stderr, "sebtype: %s\n", e.what());
        items.clear();
      }
      if (paths_.rankDelay.count()) std::this_thread::sleep_for(paths_.rankDelay);
      l.lock();
      if (job.rev != revNow_) continue;  // typed on meanwhile
      // A pick of the model's own is learned under the syllables typed (#518): only whole ones (not initials,
      // "w m"), a character each, as Rime's user dictionary keeps its words.
      if (!job.syllables.empty() &&
          std::ranges::all_of(job.syllables, [&](const std::string &s) { return readings.syllables.count(s) > 0; })) {
        std::string code;
        for (const auto &s : job.syllables) code += (code.empty() ? "" : " ") + s;
        for (auto &it : items)
          if (it.rime < 0 && wholeInput(it.simplified, job.syllables.size())) it.code = code;
      }
      result_ = std::move(items);
      resultFirst_ = first;
      resultRev_ = job.rev;
      results_++;
      if (job.fix.empty()) jobTime_ = std::chrono::steady_clock::now() - start;
      else fixDone_ = job.rev;
      // A list for the input: once it has shown, the caller's thread looks up the corrections (askFixes).
      const bool fixes = job.fixable && job.fix.empty() && first;
      if (fixes) fixDue_ = job.rev;
      done_.notify_all();
      l.unlock();
      if (ready_ && changed) ready_();  // a correction that changed nothing redraws nothing
      if (ready_ && fixes) ready_();
      l.lock();
    }
  }

  static Item own(const std::string &text, bool traditional, Converter &s2t) {
    return {{traditional ? s2t(text) : text, {}}, -1, text};
  }

  // Rime's scored candidates and the model's own, best first, by the experiment's rule.
  std::vector<Item> rank(zh_lm::Model &model, const Readings &readings, const Job &job, const std::string &context,
                         Converter &t2s, Converter &s2t, std::optional<float> &first) {
    std::string letters;
    for (char c : job.input)
      if (c != '\'') letters += c;
    std::vector<std::string> texts;
    for (const auto &t : job.rime) texts.push_back(job.traditional ? t2s(t) : t);
    std::vector<float> score = model.score(context, letters, texts);
    const bool alone = std::ranges::none_of(codePoints(context), han);
    const float rankWeight = alone ? kAloneRankWeight : kRankWeight;
    const float ownPenalty = alone ? kAloneOwnPenalty : kRankWeight * std::log1p(kOwnRank);
    std::vector<Item> items;
    for (size_t i = 0; i < texts.size(); i++) {
      score[i] -= rankWeight * std::log1p(float(job.rimeIndex[i]));
      items.push_back({{job.rime[i], {}}, job.rimeIndex[i], texts[i]});
    }
    const auto generated = model.generate(context, letters, kBeam, static_cast<int>(letters.size()));
    if (revNow_ != job.rev) return {};
    for (const auto &g : generated) {
      if (std::ranges::any_of(items, [&](const Item &it) { return it.simplified == g.text; }) ||
          readings.edits(g.text, letters) > kTypos)
        continue;
      items.push_back(own(g.text, job.traditional, s2t));
      items.back().misread = job.word && !readings.spell(g.text, job.syllables);
      score.push_back(g.logProb - ownPenalty);
    }
    std::vector<size_t> order(items.size());
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    const auto better = [&](size_t a, size_t b) { return score[a] > score[b]; };
    std::stable_sort(order.begin(), order.end(), better);
    const auto head = order.begin() + std::min(order.size(), kPlain);
    std::vector<std::string> best;
    for (auto i = order.begin(); i != head; ++i) best.push_back(items[*i].simplified);
    const std::vector<float> plain = model.plain(context, best);
    for (size_t j = 0; j < plain.size(); j++)
      score[order[j]] += (items[order[j]].rime < 0 ? kOwnPlainWeight : kPlainWeight) * plain[j];
    std::stable_sort(order.begin(), head, better);
    // Misreadings last, as list() shows them: the first is the one shown first.
    std::ranges::stable_partition(order, [&](size_t i) { return !items[i].misread; });
    std::vector<Item> out;
    for (size_t i : order) out.push_back(std::move(items[i]));
    if (!order.empty()) first = score[order[0]];
    return out;
  }

  // Puts Rime's correction into the model's list ITEMS, whose first scored FIRST: first when the model is
  // at most kFixLead less sure of it, last on the first page when at most kFixFloor less sure. False if it
  // stays where it is.
  bool fix(zh_lm::Model &model, const Readings &readings, const Job &job, const std::string &context,
           std::vector<Item> &items, float first, Converter &s2t) {
    std::string letters;
    for (char c : job.input)
      if (c != '\'') letters += c;
    if (readings.edits(job.fix, letters) > kTypos) return false;  // as the model's own (#563)
    const float lp = model.score(context, letters, {job.fix})[0] - kRankWeight * std::log1p(kOwnRank) +
                     kPlainWeight * model.plain(context, {job.fix})[0];
    size_t at;
    if (lp > first - kFixLead) at = 0;
    else if (lp > first - kFixFloor) at = std::max(job.pageSize, 1) - 1;
    else return false;
    Item item = own(job.fix, job.traditional, s2t);
    if (const auto same = std::ranges::find(items, job.fix, &Item::simplified); same != items.end()) {
      if (size_t(same - items.begin()) <= at) return false;  // as high already
      item = std::move(*same);
      item.misread = false;  // Rime's reading
      items.erase(same);
    }
    items.insert(items.begin() + std::min(at, items.size()), std::move(item));
    return true;
  }

  std::unique_ptr<Engine> rime_;
  ChineseModelPaths paths_;
  std::function<void()> ready_;
  Field field_ = Field::Text;
  bool learning_ = true;
  std::string context_;  // the field's text before the composition
  std::string commit_;

  // The engine thread's: the revision, and the list last made for it (the one the frontend shows).
  uint64_t rev_ = 0;
  std::vector<Item> shown_;
  uint64_t shownRev_ = ~uint64_t{0};
  bool modelShown_ = false;  // shown_ is the model's
  bool shownComposing_ = false;  // shown_ was made for something being typed
  std::string shownInput_;       // Rime's input shown_ was made for
  int highlight_ = 0;        // in shown_, while it is the model's
  uint64_t fixAsked_ = ~uint64_t{0};  // the revision whose corrections were looked up
  uint64_t shownResult_ = 0;          // results_ when shown_ was made

  // Shared with the worker, under mutex_ (revNow_ also read in the model's steps).
  std::thread worker_;
  std::mutex mutex_;
  std::condition_variable wake_, done_;
  bool stop_ = false, loading_ = true, model_ = false;
  std::optional<Job> wanted_;
  std::vector<Item> result_;
  std::optional<float> resultFirst_;  // the model's score of result_'s first
  uint64_t resultRev_ = ~uint64_t{0};
  std::atomic<uint64_t> results_{0};             // lists that came, ever
  std::atomic<uint64_t> fixDue_{~uint64_t{0}};   // the revision whose corrections the worker asked for (#478)
  uint64_t fixDone_ = ~uint64_t{0};             // the revision whose corrections were weighed, or had none
  uint64_t askedRev_ = ~uint64_t{0};          // the last revision the model was asked a list for
  std::chrono::steady_clock::duration jobTime_{};  // how long the last list that came took
  std::atomic<uint64_t> revNow_{0};
  std::atomic<uint64_t> working_{~uint64_t{0}};
};

}  // namespace

std::unique_ptr<Engine> withChineseModel(std::unique_ptr<Engine> rime, const ChineseModelPaths &paths,
                                         std::function<void()> ready) {
  return std::make_unique<Chinese>(std::move(rime), paths, std::move(ready));
}

}  // namespace sebtype
