// SPDX-License-Identifier: LGPL-2.1-or-later
// SebType core: 中文 through librime. Session handling, the preedit, the candidate labels and switching
// follow fcitx5-rime (Copyright 2017 Xuetian Weng and contributors), whose defaults SebType's Linux users
// had before, so this file keeps fcitx5-rime's licence: see core/README.md.
#include <sebtype/hosts.h>

#include <rime_api.h>

#ifdef __GLIBC__
#include <malloc.h>
#endif

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <utility>
#include <vector>

namespace sebtype {

namespace {

// Rime's modifier masks (rime/key_table.h): X11's, plus its own Super and release bits.
constexpr uint32_t kRimeSuper = 1 << 26, kRimeRelease = 1 << 30;

class Rime final : public Engine {
 public:
  explicit Rime(const RimePaths &paths) : paths_(paths), api_(rime_get_api()) {
    RIME_STRUCT(RimeTraits, traits);
    traits.shared_data_dir = paths_.sharedDir.c_str();
    traits.user_data_dir = paths_.userDir.c_str();
    // The names of the frontend each platform had before (fcitx5-rime, SebType's Weasel): Rime's
    // installation.yaml and sync folders keep them.
#ifdef _WIN32
    traits.app_name = "rime.weasel";
    traits.distribution_name = "中文";
    traits.distribution_code_name = "Weasel";
    traits.distribution_version = "0.17.4";
#elif defined(__ANDROID__)
    // RimeJni's, which the phone had before.
    traits.app_name = "dev.sebb.sebtype";
    traits.distribution_name = "Rime for Android";
    traits.distribution_code_name = "Android";
    traits.distribution_version = api_->get_version();
#else
    traits.app_name = "rime.fcitx-rime";
    traits.distribution_name = "Rime";
    traits.distribution_code_name = "fcitx-rime";
    traits.distribution_version = "5.1.15";
#endif
    traits.log_dir = paths_.logDir.c_str();
    traits.min_log_level = 2;
    static bool setUp = false;
    if (!setUp) {
      api_->setup(&traits);
      setUp = true;
    }
    traits_ = traits;
    start(false);
  }

  ~Rime() override {
    if (session_) api_->destroy_session(session_);
    api_->finalize();
  }

  bool key(const Key &k) override {
    if (plain_ || !ready()) return false;
    uint32_t mask = k.mods & (mod::Shift | mod::Lock | mod::Ctrl | mod::Alt);
    if (k.mods & mod::Super) mask |= mod::Super | kRimeSuper;
    if (k.release) mask |= kRimeRelease;
    const bool taken = api_->process_key(session_, static_cast<int>(k.sym), static_cast<int>(mask));
    collect();
    return taken;
  }

  std::string takeCommit() override { return std::exchange(commit_, {}); }

  Preedit preedit() override {
    Preedit p;
    withContext([&](const RimeContext &c) {
      const auto &comp = c.composition;
      if (comp.length <= 0 || comp.sel_start < 0 || comp.sel_start > comp.sel_end || comp.sel_end > comp.length) return;
      auto part = [&](int from, int to, bool highlight) {
        if (from < to) p.segments.push_back({std::string(comp.preedit + from, comp.preedit + to), true, highlight});
      };
      part(0, comp.sel_start, false);
      part(comp.sel_start, comp.sel_end, true);
      part(comp.sel_end, comp.length, false);
      p.cursor = 0;  // fcitx5-rime's default on Linux: the inline cursor stays at the start
    });
    return p;
  }

  // The preedit without the spaces Rime shows between syllables: ni hao → nihao, 你 hao → 你hao.
  std::string unfinished() override {
    std::string s = preedit().text();
    std::erase(s, ' ');
    return s;
  }

  std::string input() override {
    const char *in = ready() ? api_->get_input(session_) : nullptr;
    return in ? in : "";
  }

  bool composing() override {
    bool yes = false;
    withContext([&](const RimeContext &c) { yes = c.composition.length > 0; });
    return yes;
  }

  // Leaving 中文 commits what the line would commit (fcitx5-rime's default, commit preview).
  void flush() override {
    withContext([&](const RimeContext &c) {
      if (c.composition.length > 0 && c.commit_text_preview) commit_ += c.commit_text_preview;
    });
    clear();
  }

  void clear() override {
    if (ready()) api_->clear_composition(session_);
    cache_.clear();
  }

  int pageSize() override {
    int size = 0;
    withContext([&](const RimeContext &c) { size = c.menu.page_size; });
    return size;
  }

  int highlighted() override {
    int h = -1;
    withContext([&](const RimeContext &c) {
      if (c.menu.num_candidates) h = c.menu.page_no * c.menu.page_size + c.menu.highlighted_candidate_index;
    });
    return h;
  }

  std::vector<Candidate> candidates(int max) override {
    std::vector<Candidate> list;
    RimeCandidateListIterator it{};
    if (!ready() || !api_->candidate_list_begin(session_, &it)) return list;
    while (static_cast<int>(list.size()) < max && api_->candidate_list_next(&it)) {
      list.push_back({it.candidate.text ? it.candidate.text : "", it.candidate.comment ? it.candidate.comment : ""});
    }
    api_->candidate_list_end(&it);
    // The data's last filter names the first candidate when it is a learned word: the property holds its text.
    // Room for one byte more than the first's text and a terminator Rime's strncpy never overwrites: a
    // longer property doesn't match, and a learned phrase of any length is read whole.
    if (!list.empty()) {
      std::vector<char> learned(list[0].text.size() + 2, '\0');
      if (api_->get_property(session_, "sebtype_learned", learned.data(), learned.size() - 1))
        list[0].learned = list[0].text == learned.data();
    }
    return list;
  }

  // Password fields (and on the phone fields that want no suggestions) get plain letters: Rime never sees
  // the keys, so there is nothing to show or learn (#30).
  void setField(Field field) override {
    plain_ = field == Field::Password || field == Field::Plain;
    if (plain_) clear();
  }

  void applySettings(const Settings &s, bool learning) override {
    options_.clear();
    if (s.traditional) options_.emplace_back("traditionalization", *s.traditional);
    if (s.fullWidthPunctuation) options_.emplace_back("ascii_punct", !*s.fullWidthPunctuation);
    if (s.emoji) options_.emplace_back("emoji", *s.emoji);
    // SebType's librime option (Memory::OnCommit in engines/librime): learns nothing from commits while on.
    options_.emplace_back("no_learning", !learning);
    if (session_ && !api_->is_maintenance_mode() && api_->find_session(session_)) setOptions();
  }

  bool candidateAt(int index, Candidate &out) override {
    if (index < cacheStart_ || index >= cacheStart_ + static_cast<int>(cache_.size())) fill(index);
    const int i = index - cacheStart_;
    if (i < 0 || i >= static_cast<int>(cache_.size())) return false;
    out = cache_[i];
    return true;
  }

  // Rime's own labels when the schema has them, else its select keys (fcitx5-rime's RimeCandidateList).
  std::string label(int indexOnPage) override {
    std::string label = Engine::label(indexOnPage);
    withContext([&](const RimeContext &c) {
      const bool hasLabels = RIME_STRUCT_HAS_MEMBER(c, c.select_labels) && c.select_labels;
      const int keys = c.menu.select_keys ? static_cast<int>(std::strlen(c.menu.select_keys)) : 0;
      if (hasLabels && indexOnPage < c.menu.page_size) label = std::string(c.select_labels[indexOnPage]) + " ";
      else if (indexOnPage < keys) label = std::string(1, c.menu.select_keys[indexOnPage]) + " ";
    });
    return label;
  }

  void selectAt(int index) override {
    if (!ready()) return;
    api_->select_candidate(session_, index);
    collect();
  }

  void highlightAt(int index) override {
    if (!ready()) return;
    api_->highlight_candidate(session_, index);
    cache_.clear();
  }

  bool latin() override { return option("ascii_mode"); }

  // The Shift tap switches as rime-ice's ascii_composer/switch_key says: Shift_L commits the typed
  // letters (commit_code), Shift_R does nothing (noop).
  bool shiftTapSwitches(uint32_t sym) override {
    tapStyle_ = switchKey(sym == 0xffe2 ? "Shift_R" : "Shift_L");
    return tapStyle_ != "noop";
  }

  void setLatin(bool on) override {
    if (!ready()) return;
    if (on && composing()) {
      if (tapStyle_ == "commit_text") {
        withContext([&](const RimeContext &c) {
          if (c.commit_text_preview) commit_ += c.commit_text_preview;
        });
      } else if (tapStyle_ != "clear" && tapStyle_ != "set_ascii_mode") {
        if (const char *input = api_->get_input(session_)) commit_ += input;
      }
      api_->clear_composition(session_);
    }
    api_->set_option(session_, "ascii_mode", on);
    tapStyle_ = "commit_code";
    cache_.clear();
  }

  bool alternate() override { return option("traditionalization"); }
  void setAlternate(bool on) override {
    // Kept for the next session, as a setting would be.
    auto kept = std::ranges::find(options_, std::string("traditionalization"), &std::pair<std::string, bool>::first);
    if (kept != options_.end()) kept->second = on;
    else options_.emplace_back("traditionalization", on);
    if (!ready()) return;
    api_->set_option(session_, "traditionalization", on);
    cache_.clear();
  }

  void deploy() override {
    // One that runs already (a new engine's first start) takes in the files as they are: restarting it
    // would wait for it, then build everything again.
    if (api_->is_maintenance_mode()) return;
    endSession();
    api_->finalize();
    start(true);
  }

  // With Rime stopped, so no database is open and no sync writes a snapshot back (#375).
  void forget() override {
    api_->join_maintenance_thread();  // a deploy's tasks open the user dictionaries too
    endSession();
    api_->finalize();
    forgetError_ = forgetLearned();
    start(false);
  }
  std::string forgetError() const override { return forgetError_; }

  // Saves learned words and merges the other devices' snapshots (Rime's sync, #12).
  void save() override {
    endSession();
    // The sync is a deployer task, whose module only a maintenance loads: a start from prebuilt tables
    // runs none, and without it Rime finds no such task and syncs nothing.
    api_->deployer_initialize(nullptr);
    api_->sync_user_data();
  }
  bool busy() override { return api_->is_maintenance_mode(); }
  bool available() override { return busy() || ready(); }

 private:
  void start(bool fullCheck) {
    api_->initialize(&traits_);
    if (fullCheck || !paths_.prebuilt) api_->start_maintenance(fullCheck);
    trim_ = true;
  }

  // Rime takes no keys while it deploys (in its own thread) after a start.
  bool ready() {
    if (api_->is_maintenance_mode()) return false;
#ifdef __GLIBC__
    // A deploy frees hundreds of MB, but glibc keeps the pages: Fcitx5 stayed near 100 MB RSS after a
    // fresh profile, against about 40 MB after a second start (#214).
    if (std::exchange(trim_, false)) malloc_trim(0);
#endif
    if (!session_ || !api_->find_session(session_)) {
      session_ = api_->create_session();
      cache_.clear();
      if (!session_) return false;
      // Selecting a schema resets its switches, so the options come after.
      if (!paths_.schema.empty()) api_->select_schema(session_, paths_.schema.c_str());
      setOptions();
    }
    return true;
  }

  // What Rime learned: its user dictionaries (*.userdb) and their snapshots (*.userdb.txt, *.userdb.kct from
  // older Rimes), in the sync folder too; My words' sync record stays (as the Configurator's rime.rs counts).
  // A sync folder outside the user folder (#396) may hold files that aren't Rime's: only snapshots go there.
  // Empty when all of it is gone, else the file or folder that failed and why.
  std::string forgetLearned() {
    namespace fs = std::filesystem;
    const auto failed = [](const fs::path &p, const std::error_code &ec) {
      const std::u8string u = p.u8string();
      return std::string(u.begin(), u.end()) + ": " + ec.message();
    };
    std::vector<fs::path> learned;
    const auto scan = [&](const fs::path &dir, bool snapshotsOnly) -> std::string {
      std::error_code ec;
      fs::recursive_directory_iterator it(dir, ec), end;
      if (ec == std::errc::no_such_file_or_directory) return {};  // a profile that never learned
      for (; !ec && it != end; it.increment(ec)) {
        const std::string name = it->path().filename().string();
        if (name.ends_with(".userdb") && it->is_directory(ec)) {
          if (!snapshotsOnly) learned.push_back(it->path());
          it.disable_recursion_pending();
        } else if (name != "zh_my_words.userdb.txt" && (name.ends_with(".userdb.txt") || name.ends_with(".userdb.kct"))) {
          learned.push_back(it->path());
        }
        if (ec) return failed(it->path(), ec);
      }
      return ec ? failed(dir, ec) : std::string();
    };
    const fs::path dir = fs::u8path(paths_.userDir);
    if (std::string error = scan(dir, false); !error.empty()) return error;
    const fs::path sync = syncDir(dir);
    std::error_code ec;
    const fs::path inUserDir = fs::weakly_canonical(sync, ec).lexically_relative(fs::weakly_canonical(dir, ec));
    if (inUserDir.empty() || *inUserDir.begin() == "..")  // inside, the scan above had it
      if (std::string error = scan(sync, true); !error.empty()) return error;
    for (const auto &p : learned)
      if (fs::remove_all(p, ec); ec) return failed(p, ec);  // one already gone is no error
    return {};
  }

  // Rime's sync folder: installation.yaml's sync_dir, else <user folder>/sync. Read here, as Rime reads it: Rime
  // reads it only in a maintenance or sync, so get_user_data_sync_dir may still say the default.
  std::filesystem::path syncDir(const std::filesystem::path &userDir) {
    std::ifstream in(userDir / "installation.yaml");
    std::stringstream yaml;
    yaml << in.rdbuf();
    RimeConfig config = {};
    std::filesystem::path sync = userDir / "sync";
    if (api_->config_load_string(&config, yaml.str().c_str())) {
      if (const char *v = api_->config_get_cstring(&config, "sync_dir"); v && *v) sync = std::filesystem::u8path(v);
      api_->config_close(&config);
    }
    return sync;
  }

  void endSession() {
    if (session_) api_->destroy_session(session_);
    session_ = 0;
    cache_.clear();
  }

  void collect() {
    RIME_STRUCT(RimeCommit, commit);
    if (api_->get_commit(session_, &commit)) {
      commit_ += commit.text;
      api_->free_commit(&commit);
    }
    cache_.clear();
  }

  template <typename F>
  void withContext(F &&f) {
    if (!ready()) return;
    RIME_STRUCT(RimeContext, context);
    if (!api_->get_context(session_, &context)) return;
    f(context);
    api_->free_context(&context);
  }

  void setOptions() {
    for (const auto &[name, value] : options_) api_->set_option(session_, name.c_str(), value);
  }

  bool option(const char *name) { return ready() && api_->get_option(session_, name); }

  // The candidates from index on, one page and one more (to know whether a next page exists).
  void fill(int index) {
    cache_.clear();
    cacheStart_ = index;
    RimeCandidateListIterator it{};
    if (!ready() || !api_->candidate_list_from_index(session_, &it, index)) return;
    const int want = std::max(pageSize(), 1) + 1;
    while (static_cast<int>(cache_.size()) < want && api_->candidate_list_next(&it)) {
      cache_.push_back({it.candidate.text ? it.candidate.text : "", it.candidate.comment ? it.candidate.comment : ""});
    }
    api_->candidate_list_end(&it);
  }

  std::string switchKey(const char *key) {
    std::string style;
    RimeConfig config{};
    RIME_STRUCT(RimeStatus, status);
    if (!ready() || !api_->get_status(session_, &status)) return "commit_code";
    const std::string schema = status.schema_id ? status.schema_id : "";
    api_->free_status(&status);
    const std::string path = std::string("ascii_composer/switch_key/") + key;
    for (const char *name : {schema.c_str(), "default"}) {
      bool opened = name == schema.c_str() ? api_->schema_open(name, &config) : api_->config_open(name, &config);
      if (!opened) continue;
      if (const char *v = api_->config_get_cstring(&config, path.c_str())) style = v;
      api_->config_close(&config);
      if (!style.empty()) break;
    }
    return style.empty() ? "commit_code" : style;
  }

  RimePaths paths_;
  RimeApi *api_;
  RimeTraits traits_{};
  RimeSessionId session_ = 0;
  bool trim_ = false;  // a start (perhaps a deploy) ran since the last trim
  std::string forgetError_;
  bool plain_ = false;
  std::vector<std::pair<std::string, bool>> options_;
  std::string commit_, tapStyle_ = "commit_code";
  std::vector<Candidate> cache_;
  int cacheStart_ = 0;
};

}  // namespace

std::unique_ptr<Engine> makeRime(const RimePaths &paths) { return std::make_unique<Rime>(paths); }

}  // namespace sebtype
