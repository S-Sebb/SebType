// SebType core: English on the phone (#244). Pristine AOSP LatinIME's decoder (engines/latinime, Apache-2.0)
// finds the words near the letters typed and keeps the learned words; SebType's model (engines/sebtype-lm)
// ranks them, decides what a space corrects and predicts the next words. MIT, SebType.
//
// Threads: keys, the decoder and the ranking run on the caller's thread, as every engine's keys do. The
// model loads on a worker thread once the first letter is typed (Decisions #2, 2026-11-11: until then the
// decoder decides alone), and next words are computed there and posted back through READY (plan §3).
#include <sebtype/hosts.h>

#include <jni.h>
#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <string_view>
#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <ctime>
#include <mutex>
#include <optional>
#include <thread>
#include <type_traits>
#include <utility>

#include "dictionary/property/historical_info.h"
#include "dictionary/property/ngram_context.h"
#include "dictionary/structure/dictionary_structure_with_buffer_policy_factory.h"
#include "dictionary/utils/dict_file_writing_utils.h"
#include "dictionary/utils/file_utils.h"
#include "sebtype_lm.h"
#include "suggest/core/dictionary/dictionary.h"
#include "suggest/core/layout/proximity_info.h"
#include "suggest/core/result/suggestion_results.h"
#include "suggest/core/session/dic_traverse_session.h"
#include "suggest/core/suggest_options.h"
#include "utils/autocorrection_threshold_utils.h"

namespace sebtype {
namespace {

using latinime::Dictionary;

constexpr int kMaxWordLength = MAX_WORD_LENGTH;  // AOSP's: longer words get no suggestions
constexpr int kMaxResults = MAX_RESULTS;          // the decoder's results per call (AOSP's 18)
constexpr int kPrevWords = MAX_PREV_WORD_COUNT_FOR_N_GRAM;
// AOSP's "modest" autocorrection, the rule until the model has loaded (Suggest.getSuggestedWordsForNonBatchInput).
constexpr float kAutocorrectThreshold = 0.185f;
constexpr size_t kNextWords = 5;      // the model's next words asked for; blocked ones leave the list
constexpr size_t kContextChars = 1000;  // the text before the cursor kept; the model reads 300 of it
// Typing options: not a gesture, no full edit distance, offensive words blocked, locale weight 1.0.
constexpr int kOptions[] = {0, 0, 1, 0, 1000};
namespace ks {
constexpr uint32_t BackSpace = 0xff08, Tab = 0xff09, Return = 0xff0d, KP_Enter = 0xff8d;
}
// After "@": the common mail domains (#53 B10), most used first.
const char *const kEmailDomains[] = {"gmail.com",   "outlook.com", "hotmail.com", "yahoo.com", "icloud.com",
                                     "proton.me",   "qq.com",      "163.com",     "126.com",   "foxmail.com",
                                     "live.com",    "aol.com",     "gmx.com",     "mail.com",  "protonmail.com"};

// --- AOSP's decoder without Java ---
//
// The decoder takes the keyboard and returns its results as Java arrays. This JNIEnv has only the array
// copies those need, over plain arrays, and no Java classes (the decoder's log call finds none and stops).
template <class T>
struct Buf {
  T *data;
  jsize size;
};
template <class T>
auto jarr(Buf<T> &b) {
  if constexpr (std::is_same_v<T, jint>) return reinterpret_cast<jintArray>(&b);
  else return reinterpret_cast<jfloatArray>(&b);
}

JNIEnv *arrayEnv() {
  using Fns = std::remove_const_t<std::remove_pointer_t<decltype(std::declval<JNIEnv &>().functions)>>;
  static Fns fns = [] {
    Fns f{};
    f.FindClass = [](JNIEnv *, const char *) -> jclass { return nullptr; };
    f.ExceptionClear = [](JNIEnv *) {};
    f.GetArrayLength = [](JNIEnv *, jarray a) { return reinterpret_cast<Buf<jint> *>(a)->size; };
    f.GetIntArrayRegion = [](JNIEnv *, jintArray a, jsize at, jsize n, jint *out) {
      std::copy_n(reinterpret_cast<Buf<jint> *>(a)->data + at, n, out);
    };
    f.GetFloatArrayRegion = [](JNIEnv *, jfloatArray a, jsize at, jsize n, jfloat *out) {
      std::copy_n(reinterpret_cast<Buf<jfloat> *>(a)->data + at, n, out);
    };
    f.SetIntArrayRegion = [](JNIEnv *, jintArray a, jsize at, jsize n, const jint *in) {
      std::copy_n(in, n, reinterpret_cast<Buf<jint> *>(a)->data + at);
    };
    f.SetFloatArrayRegion = [](JNIEnv *, jfloatArray a, jsize at, jsize n, const jfloat *in) {
      std::copy_n(in, n, reinterpret_cast<Buf<jfloat> *>(a)->data + at);
    };
    return f;
  }();
  static JNIEnv env{&fns};
  return &env;
}

std::vector<int> codePoints(const std::string &s) {
  std::vector<int> out;
  for (size_t i = 0; i < s.size();) {
    const unsigned char c = s[i];
    const int n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
    int cp = n == 1 ? c : c & (0x3f >> (n - 1));
    for (int k = 1; k < n && i + k < s.size(); k++) cp = cp << 6 | (s[i + k] & 0x3f);
    out.push_back(cp);
    i += n;
  }
  return out;
}

std::string utf8(char32_t cp) {
  std::string s;
  if (cp < 0x80) {
    s += char(cp);
  } else if (cp < 0x800) {
    s += char(0xc0 | cp >> 6), s += char(0x80 | (cp & 0x3f));
  } else if (cp < 0x10000) {
    s += char(0xe0 | cp >> 12), s += char(0x80 | (cp >> 6 & 0x3f)), s += char(0x80 | (cp & 0x3f));
  } else {
    s += char(0xf0 | cp >> 18), s += char(0x80 | (cp >> 12 & 0x3f)), s += char(0x80 | (cp >> 6 & 0x3f));
    s += char(0x80 | (cp & 0x3f));
  }
  return s;
}

std::string utf8(const std::vector<int> &cps) {
  std::string s;
  for (int c : cps) s += utf8(char32_t(c));
  return s;
}

// The Latin-1 letters and the code point of a key (0 for function keys).
bool isLetter(char32_t c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= 0xc0 && c <= 0xff && c != 0xd7 && c != 0xf7);
}
char32_t lowerCase(char32_t c) { return (c >= 'A' && c <= 'Z') || (c >= 0xc0 && c <= 0xde && c != 0xd7) ? c + 32 : c; }
char32_t upperCase(char32_t c) { return (c >= 'a' && c <= 'z') || (c >= 0xe0 && c <= 0xfe && c != 0xf7) ? c - 32 : c; }
char32_t keyChar(uint32_t sym) {
  if (sym >= 0x1000000) return sym - 0x1000000;  // X11's Unicode keysyms
  return sym >= 0x20 && sym < 0x100 && sym != 0x7f ? sym : 0;
}
// Separators that end a word and let a space correct it, as AOSP's English ones.
bool isSeparator(char32_t c) { return c == ' ' || std::u32string_view(U".,;:!?)]}\"").find(c) != std::u32string_view::npos; }
// Punctuation that joins the word before it when it comes right after a picked suggestion (#39).
bool joinsWord(char32_t c) { return std::u32string_view(U".,;:!?").find(c) != std::u32string_view::npos; }

std::string withCase(const std::string &word, const std::vector<int> &typed) {
  if (typed.empty() || char32_t(typed[0]) == lowerCase(typed[0])) return word;
  const bool allCaps = typed.size() > 1 && std::all_of(typed.begin(), typed.end(), [](int c) {
                         return char32_t(c) == upperCase(c);
                       });
  auto cps = codePoints(word);
  for (size_t i = 0; i < cps.size() && (allCaps || i == 0); i++) cps[i] = upperCase(cps[i]);
  return utf8(cps);
}

// One decoder result, as SuggestedWordInfo holds it.
struct Word {
  std::string word;
  int score;
  int kind;
};

// SuggestionResults: the best CAPACITY words by score, then shorter first, then alphabetically; a word that
// ties another on all three is dropped, as in the TreeSet AOSP keeps them in.
void addResult(std::vector<Word> &results, const Word &w, size_t capacity) {
  auto length = [](const std::string &s) { return std::count_if(s.begin(), s.end(), [](char c) { return (c & 0xc0) != 0x80; }); };
  auto before = [&](const Word &a, const Word &b) {
    if (a.score != b.score) return a.score > b.score;
    if (length(a.word) != length(b.word)) return length(a.word) < length(b.word);
    return a.word < b.word;
  };
  auto at = std::lower_bound(results.begin(), results.end(), w, before);
  const bool duplicate = at != results.end() && !before(w, *at);
  if (results.size() < capacity) {
    if (!duplicate) results.insert(at, w);
    return;
  }
  if (at == results.end()) return;
  if (!duplicate) results.insert(at, w);
  results.pop_back();
}

// Up to three words before the cursor in the last line of CONTEXT, nearest first, as AOSP's NgramContext
// takes them: a word ending a sentence (or no word) is the beginning of a sentence; a word ending in other
// punctuation ends the context.
latinime::NgramContext ngramContext(const std::string &context) {
  const auto nl = context.rfind('\n');
  const std::string line = nl == std::string::npos ? context : context.substr(nl + 1);
  std::vector<std::string> words;
  for (size_t i = 0; i < line.size();) {
    const size_t start = line.find_first_not_of(" \t", i);
    if (start == std::string::npos) break;
    const size_t end = std::min(line.find_first_of(" \t", start), line.size());
    words.push_back(line.substr(start, end - start));
    i = end;
  }
  int prev[kPrevWords][kMaxWordLength];
  int counts[kPrevWords] = {};
  bool bos[kPrevWords] = {};
  for (int i = 0; i < kPrevWords; i++) {
    const int at = int(words.size()) - 1 - i;
    const char last = at < 0 ? '.' : words[at].back();
    if (last == '.' || last == '!' || last == '?') {
      bos[i] = true;
      break;
    }
    if (!std::isalnum(static_cast<unsigned char>(last)) && last != '\'') break;
    const auto cps = codePoints(words[at]);
    if (cps.size() > size_t(kMaxWordLength)) break;
    std::copy(cps.begin(), cps.end(), prev[i]);
    counts[i] = int(cps.size());
  }
  return latinime::NgramContext(prev, counts, bos, kPrevWords);
}

// A dictionary and the decoder's session on it.
struct Lexicon {
  std::unique_ptr<Dictionary> dict;
  std::unique_ptr<latinime::DicTraverseSession> session;

  static std::unique_ptr<Lexicon> open(const std::string &path, int64_t offset, int64_t length, bool updatable) {
    struct stat st{};
    if (stat(path.c_str(), &st) != 0) return nullptr;
    if (!length && S_ISREG(st.st_mode)) length = st.st_size - offset;
    auto policy = latinime::DictionaryStructureWithBufferPolicyFactory::newPolicyForExistingDictFile(
        path.c_str(), int(offset), int(length), updatable);
    if (!policy) return nullptr;
    auto lex = std::make_unique<Lexicon>();
    lex->dict = std::make_unique<Dictionary>(arrayEnv(), std::move(policy));
    lex->session.reset(static_cast<latinime::DicTraverseSession *>(
        latinime::DicTraverseSession::getSessionInstance(arrayEnv(), nullptr, length)));
    latinime::NgramContext none;
    lex->session->init(lex->dict.get(), &none, nullptr);
    return lex;
  }

  // The words near TYPED (code points, with one touch point each) after CONTEXT.
  std::vector<Word> suggest(latinime::ProximityInfo *keys, const std::vector<int> &typed, std::vector<int> xs,
                            std::vector<int> ys, const latinime::NgramContext &context) {
    if (typed.empty() || typed.size() >= size_t(kMaxWordLength)) return {};
    std::vector<int> input(kMaxWordLength, NOT_A_CODE_POINT), times(typed.size()), pointers(typed.size());
    std::copy(typed.begin(), typed.end(), input.begin());
    latinime::SuggestOptions options(kOptions, int(std::size(kOptions)));
    latinime::SuggestionResults results(kMaxResults);
    dict->getSuggestions(keys, session.get(), xs.data(), ys.data(), times.data(), pointers.data(), input.data(),
                         int(typed.size()), &context, &options, NOT_A_WEIGHT_OF_LANG_MODEL_VS_SPATIAL_MODEL, &results);
    return words(results);
  }

  // The words that followed CONTEXT in this dictionary: its n-grams (the learned words have them).
  std::vector<Word> predict(const latinime::NgramContext &context) {
    latinime::SuggestionResults results(kMaxResults);
    dict->getPredictions(&context, &results);
    return words(results);
  }

  static std::vector<Word> words(latinime::SuggestionResults &results) {
    std::vector<jint> count(1), outCodes(kMaxWordLength * kMaxResults), scores(kMaxResults), spaces(kMaxResults),
        kinds(kMaxResults), confidence(1);
    std::vector<jfloat> weight(1);
    Buf<jint> c{count.data(), 1}, o{outCodes.data(), jsize(outCodes.size())}, s{scores.data(), kMaxResults},
        sp{spaces.data(), kMaxResults}, k{kinds.data(), kMaxResults}, cf{confidence.data(), 1};
    Buf<jfloat> w{weight.data(), 1};
    results.outputSuggestions(arrayEnv(), jarr(c), jarr(o), jarr(s), jarr(sp), jarr(k), jarr(cf), jarr(w));
    std::vector<Word> out;
    for (int j = 0; j < count[0]; j++) {
      std::vector<int> cps;
      for (int i = 0; i < kMaxWordLength && outCodes[j * kMaxWordLength + i]; i++) cps.push_back(outCodes[j * kMaxWordLength + i]);
      if (!cps.empty()) out.push_back({utf8(cps), scores[j], kinds[j]});
    }
    return out;
  }

  bool has(const std::string &word) const {
    const auto cps = codePoints(word);
    return dict->getProbability(latinime::CodePointArrayView(cps)) != NOT_A_PROBABILITY;
  }
  bool offensive(const std::string &word) const {
    const auto cps = codePoints(word);
    return has(word) &&
           dict->getWordProperty(latinime::CodePointArrayView(cps)).getUnigramProperty().isPossiblyOffensive();
  }
};

float normalizedScore(const std::vector<int> &typed, const std::string &word, int score) {
  const auto after = codePoints(word);
  return latinime::AutocorrectionThresholdUtils::calcNormalizedScore(typed.data(), int(typed.size()), after.data(),
                                                                       int(after.size()), score);
}

// The keyboard SebType's harness and #46 use until the frontend sends its own: a 1080 x 640 px QWERTY of
// 108 x 160 px keys, with comma, space and period on the bottom row.
Layout defaultLayout() {
  Layout l{1080, 640, {}};
  const char *rows[] = {"qwertyuiop", "asdfghjkl", "zxcvbnm"};
  const int indent[] = {0, 54, 162};
  for (int r = 0; r < 3; r++)
    for (int i = 0; rows[r][i]; i++) l.keys.push_back({char32_t(rows[r][i]), indent[r] + i * 108, r * 160, 108, 160});
  l.keys.push_back({U',', 162, 480, 108, 160});
  l.keys.push_back({U' ', 270, 480, 540, 160});
  l.keys.push_back({U'.', 810, 480, 108, 160});
  return l;
}

// AOSP's ProximityInfo for LAYOUT: the 32 x 16 grid with the keys within 1.2 key widths of each cell, and
// touch position correction (the "holo" data AOSP's keyboards load).
std::unique_ptr<latinime::ProximityInfo> proximityInfo(const Layout &layout) {
  constexpr int gridW = 32, gridH = 16, maxProximityChars = 16;
  constexpr float searchDistance = 1.2f, defaultRadius = 0.15f;
  constexpr float correctionY[] = {-0.0005677f, 0.0381731f, 0.0880847f};
  constexpr float correctionRadius[] = {0.1577026f, 0.1529972f, 0.1522819f};
  std::vector<KeyRect> keys;
  for (const auto &k : layout.keys)
    if (k.code >= ' ') keys.push_back(k);
  // The most common key size.
  std::map<std::pair<int, int>, int> sizes;
  for (const auto &k : keys) sizes[{k.width, k.height}]++;
  const auto common = std::max_element(sizes.begin(), sizes.end(), [](auto &a, auto &b) { return a.second < b.second; });
  const int keyW = common == sizes.end() ? 1 : common->first.first, keyH = common == sizes.end() ? 1 : common->first.second;
  const int cellW = (layout.width + gridW - 1) / gridW, cellH = (layout.height + gridH - 1) / gridH;
  const int threshold = int(keyW * searchDistance);

  std::vector<jint> proximity(gridW * gridH * maxProximityChars, -1);
  for (int cell = 0; cell < gridW * gridH; cell++) {
    const int cx = cell % gridW * cellW + cellW / 2, cy = cell / gridW * cellH + cellH / 2;
    int n = 0;
    for (const auto &k : keys) {
      const int dx = cx - std::clamp(cx, k.x, k.x + k.width), dy = cy - std::clamp(cy, k.y, k.y + k.height);
      if (dx * dx + dy * dy < threshold * threshold && n < maxProximityChars)
        proximity[cell * maxProximityChars + n++] = jint(k.code);
    }
  }
  std::vector<jint> xs, ys, ws, hs, codes;
  std::vector<jfloat> sx, sy, sr;
  for (const auto &k : keys) {
    xs.push_back(k.x), ys.push_back(k.y), ws.push_back(k.width), hs.push_back(k.height), codes.push_back(jint(k.code));
    const int row = keyH ? k.y / keyH : 0;
    sx.push_back(k.x + k.width / 2.0f);
    sy.push_back(k.y + k.height / 2.0f + (row < 3 ? correctionY[row] * k.height : 0));
    sr.push_back(row < 3 ? correctionRadius[row] * std::hypot(float(k.width), float(k.height))
                         : defaultRadius * std::hypot(float(keyW), float(keyH)));
  }
  const jsize n = jsize(keys.size());
  Buf<jint> p{proximity.data(), jsize(proximity.size())}, bx{xs.data(), n}, by{ys.data(), n}, bw{ws.data(), n},
      bh{hs.data(), n}, bc{codes.data(), n};
  Buf<jfloat> fx{sx.data(), n}, fy{sy.data(), n}, fr{sr.data(), n};
  return std::make_unique<latinime::ProximityInfo>(arrayEnv(), layout.width, layout.height, gridW, gridH, keyW, keyH,
                                                   jarr(p), n, jarr(bx), jarr(by), jarr(bw), jarr(bh), jarr(bc),
                                                   jarr(fx), jarr(fy), jarr(fr));
}

class English : public Engine {
 public:
  English(const EnglishPaths &paths, std::function<void()> ready) : paths_(paths), ready_(std::move(ready)) {
    main_ = Lexicon::open(paths.dictionary, paths.dictionaryOffset, paths.dictionaryLength, false);
    if (!main_) std::fprintf(stderr, "sebtype: can't open the English dictionary %s\n", paths.dictionary.c_str());
    if (!paths.userDir.empty()) {
      openHistory();
      takeInLegacyHistory();
    }
    setLayout(defaultLayout());
    worker_ = std::thread([this] { work(); });
  }

  ~English() override {
    {
      std::lock_guard g(mutex_);
      stop_ = true;
    }
    wake_.notify_all();
    worker_.join();
    save();
  }

  bool key(const Key &k) override {
    if (k.release) return false;
    const char32_t c = keyChar(k.sym);
    if (k.mods & (mod::Ctrl | mod::Alt | mod::Super)) {
      commitTyped();
      return false;
    }
    if (field_ != Field::Text) {  // no suggestions: the keys go through, followed for e-mail domains
      if (k.sym == ks::BackSpace) dropLastChar();
      else if (c) context_ += utf8(c);
      changed();
      return false;
    }
    const bool afterPick = std::exchange(afterPick_, false);
    if (k.sym == ks::BackSpace) {
      if (typed_.empty()) {
        dropLastChar();
        changed();
        return false;
      }
      typed_.pop_back(), xs_.pop_back(), ys_.pop_back();
      update();
      return true;
    }
    if (isLetter(c) || ((c == '\'' || c == U'’') && !typed_.empty())) {
      if (typed_.empty()) loadModel();
      typed_.push_back(int(c));
      const auto [x, y] = k.x >= 0 ? std::pair{k.x, k.y} : keyCentre(lowerCase(c));
      xs_.push_back(x), ys_.push_back(y);
      update();
      return true;
    }
    if (k.sym == ks::Return || k.sym == ks::KP_Enter || k.sym == ks::Tab) {
      if (!typed_.empty()) commitWord(decision(), false);
      context_ += k.sym == ks::Tab ? "\t" : "\n";
      changed();
      return false;  // the frontend does the field's action or types it
    }
    if (c && isSeparator(c)) {
      if (afterPick && joinsWord(c) && context_.ends_with(' ')) {
        // "word" picked, then ".": "word. " (#39); a space the user typed keeps the period where it is.
        context_.pop_back();
        edit_.deleteBefore = 1;
      } else if (!typed_.empty()) {
        commitWord(decision(), false);
      }
      commit_ += utf8(c);
      context_ += utf8(c);
      if (edit_.deleteBefore) commit_ += " ", context_ += " ";
      changed();
      return true;
    }
    // Digits, symbols and the keys that move the cursor: the word stays as typed.
    commitTyped();
    if (c) context_ += utf8(c);
    changed();
    return false;
  }

  std::string takeCommit() override { return std::exchange(commit_, {}); }
  Edit takeEdit() override { return std::exchange(edit_, {}); }

  Preedit preedit() override {
    if (typed_.empty()) return {};
    const std::string text = utf8(typed_);
    return {{{text, true, false}}, int(text.size())};
  }
  bool composing() override { return !typed_.empty(); }
  void flush() override { commitTyped(); }
  void clear() override { resetWord(); }

  std::vector<Candidate> candidates(int max) override {
    std::vector<Candidate> out;
    for (const auto &w : list())
      if (int(out.size()) < max) out.push_back({w, {}});
    return out;
  }
  bool candidateAt(int index, Candidate &out) override {
    const auto l = list();
    if (index < 0 || size_t(index) >= l.size()) return false;
    out = {l[index], {}};
    return true;
  }
  int highlighted() override { return correction_ ? 0 : -1; }

  void selectAt(int index) override {
    const auto l = list();
    if (index < 0 || size_t(index) >= l.size()) return;
    const std::string &w = l[index];
    if (domains_) {  // the rest of an e-mail address: no space after it
      if (typed_.empty()) edit_.deleteBefore = int(codePoints(afterAt()).size());
      if (typed_.empty()) context_.erase(context_.size() - afterAt().size());
      resetWord();
      commit_ += w;
      context_ += w;
      changed();
      return;
    }
    commitWord(w, true);
    commit_ += " ";
    context_ += " ";
    afterPick_ = true;
    changed();
  }

  bool latin() override { return false; }
  void setLatin(bool) override {}
  bool shiftTapSwitches(uint32_t) override { return false; }
  bool alternate() override { return false; }
  void setAlternate(bool) override {}

  void setField(Field field) override {
    field_ = field;
    resetWord();
  }
  void applySettings(const Settings &, bool learning) override { learning_ = learning; }
  void setLayout(const Layout &layout) override {
    layout_ = layout;
    keys_ = proximityInfo(layout);
  }
  void setContext(const std::string &before) override {
    resetWord();
    context_ = before.size() > kContextChars ? before.substr(before.size() - kContextChars) : before;
    changed();
  }

  // AOSP's flush replaces the open dictionary's folder, which fails on NFS while its files are mapped
  // (removeDirAndFiles' own comment): it writes a new one beside it, which replaces it once closed.
  void save() override {
    if (!history_) return;
    const std::string path = historyPath(), saving = paths_.userDir + "/saving", saved = saving + "/en_history";
    latinime::FileUtils::removeDirAndFiles(saving.c_str());
    mkdir(saving.c_str(), 0700);
    const bool gc = history_->dict->needsToRunGC(true);
    if (gc ? history_->dict->flushWithGC(saved.c_str()) : history_->dict->flush(saved.c_str())) {
      history_.reset();
      latinime::FileUtils::removeDirAndFiles(path.c_str());
      std::rename(saved.c_str(), path.c_str());
      openHistory();
    }
    latinime::FileUtils::removeDirAndFiles(saving.c_str());
  }
  void forget() override {
    if (paths_.userDir.empty()) return;
    history_.reset();
    latinime::FileUtils::removeDirAndFiles(historyPath().c_str());
    openHistory();
    resetWord();
  }

 private:
  std::string historyPath() const { return paths_.userDir + "/en_history"; }

  // Today's app (FUTO Keyboard's, before #191 stage 6) keeps English's learned words in this same AOSP format,
  // in a folder of this name. The update moves that folder into userDir (android/next's Migration); its words
  // are learned here once, as of now, so none has faded by the time the new keyboard first opens.
  void takeInLegacyHistory() {
    const std::string legacy = paths_.userDir + "/UserHistoryDictionary.en_US.dict";
    struct stat st{};
    if (stat(legacy.c_str(), &st) != 0) return;
    if (auto old = Lexicon::open(legacy, 0, 0, false); old && history_) {
      const latinime::NgramContext none;
      std::vector<int> cps(kMaxWordLength);
      int token = 0, count = 0;
      do {
        token = old->dict->getNextWordAndNextToken(token, cps.data(), &count);
        if (count > 0)
          history_->dict->updateEntriesForWordWithNgramContext(&none, latinime::CodePointArrayView(cps.data(), count),
                                                               true, latinime::HistoricalInfo(int(std::time(nullptr)), 0, 1));
      } while (token != 0);
      save();
    }
    latinime::FileUtils::removeDirAndFiles(legacy.c_str());
  }

  // AOSP's user-history dictionary: ver4 with a forgetting curve, so a word learned stays in the list while
  // it is used and fades after weeks without use.
  void openHistory() {
    const std::string path = historyPath();
    history_ = Lexicon::open(path, 0, 0, true);
    if (history_) return;
    latinime::FileUtils::removeDirAndFiles(path.c_str());  // missing, or left unreadable
    latinime::DictionaryHeaderStructurePolicy::AttributeMap attributes;
    auto put = [&](const std::string &k, const std::string &v) { attributes[{k.begin(), k.end()}] = {v.begin(), v.end()}; };
    put("dictionary", "userhistory.en_US");
    put("locale", "en_US");
    put("version", "1");
    put("USES_FORGETTING_CURVE", "1");
    put("HAS_HISTORICAL_INFO", "1");
    const std::string locale = "en_US";
    latinime::DictFileWritingUtils::createEmptyDictFile(path.c_str(), 403, {locale.begin(), locale.end()}, &attributes);
    history_ = Lexicon::open(path, 0, 0, true);
    if (!history_) std::fprintf(stderr, "sebtype: can't open the English learned words in %s\n", path.c_str());
  }

  std::pair<int, int> keyCentre(char32_t c) const {
    for (const auto &k : layout_.keys)
      if (k.code == c) return {k.x + k.width / 2, k.y + k.height / 2};
    return {NOT_A_COORDINATE, NOT_A_COORDINATE};
  }

  // The text after the last "@" of the word before the cursor, when it has one.
  std::string afterAt() const {
    const auto start = context_.find_last_of(" \t\n");
    const std::string word = context_.substr(start == std::string::npos ? 0 : start + 1);
    const auto at = word.rfind('@');
    return at == std::string::npos ? std::string{} : word.substr(at + 1);
  }
  bool atEmail() const {
    const auto start = context_.find_last_of(" \t\n");
    return context_.find('@', start == std::string::npos ? 0 : start + 1) != std::string::npos;
  }

  std::vector<std::string> domains(const std::string &typed) const {
    std::string lower;
    for (char32_t c : codePoints(typed)) lower += utf8(lowerCase(c));
    std::vector<std::string> out;
    for (const char *d : kEmailDomains)
      if (std::string_view(d).starts_with(lower) && lower != d) out.push_back(d);
    return out;
  }

  // The list the frontend shows: while typing, the correction a space makes (if any), the typed word, then
  // the others; e-mail domains after "@"; with nothing typed, the next words: the model's once they come,
  // until then the dictionaries' (the learned words' n-grams).
  std::vector<std::string> list() {
    if (!typed_.empty()) return strip_;
    domains_ = atEmail();
    if (domains_) return domains(afterAt());
    if (field_ != Field::Text || !main_) return {};
    std::vector<std::string> words;
    {
      std::lock_guard g(mutex_);
      if (nextGen_ == gen_)
        for (const auto &w : next_) words.push_back(w.word);
    }
    if (words.empty() && history_) {
      const auto context = ngramContext(context_);
      std::vector<Word> results;
      for (const Word &w : main_->predict(context)) addResult(results, w, kMaxResults);
      for (const Word &w : history_->predict(context)) addResult(results, w, kMaxResults);
      for (const Word &w : results)
        if (std::find(words.begin(), words.end(), w.word) == words.end()) words.push_back(w.word);
    }
    std::erase_if(words, [&](const std::string &w) { return main_->offensive(w) || main_->offensive(lowerCaseWord(w)); });
    return words;
  }

  static std::string lowerCaseWord(const std::string &w) {
    std::string out;
    for (char32_t c : codePoints(w)) out += utf8(lowerCase(c));
    return out;
  }

  // The strip and the correction for the letters typed so far.
  void update() {
    changed();
    const std::string typed = utf8(typed_);
    correction_ = false;
    strip_.clear();
    // Right after "@" (an address typed in a text field): domains, never a correction.
    domains_ = !context_.empty() && context_.back() == '@';
    if (domains_) {
      strip_ = domains(typed);
      return;
    }
    if (!main_) return;
    const auto context = ngramContext(context_);
    std::vector<Word> results;
    for (const Word &w : main_->suggest(keys_.get(), typed_, xs_, ys_, context)) addResult(results, w, kMaxResults);
    if (history_)
      for (const Word &w : history_->suggest(keys_.get(), typed_, xs_, ys_, context)) addResult(results, w, kMaxResults);

    std::string committed = typed;
    std::vector<std::string> strip;
    if (model_ready_) {
      std::vector<sebtype_lm::Candidate> candidates;
      bool typedIsWord = false;
      for (const Word &w : results) {
        typedIsWord |= w.word == typed;
        candidates.push_back({w.word, normalizedScore(typed_, w.word, w.score)});
      }
      std::lock_guard g(modelMutex_);
      const auto ranked = sebtype_lm::rank(*model_, context_, typed, candidates, typedIsWord);
      strip = ranked.strip, committed = ranked.committed;
    } else {
      // AOSP's rule: the typed word leaves the list, and whether it was there decides if it may be corrected.
      bool typedFound = false;
      for (const Word &w : results) {
        if (w.word == typed) typedFound = true;
        else if (std::find(strip.begin(), strip.end(), w.word) == strip.end()) strip.push_back(w.word);
      }
      if (!results.empty() && !strip.empty()) {
        const Word &first = results.front();
        const int kind = first.kind & Dictionary::KIND_MASK_KIND;
        const bool whitelisted = kind == Dictionary::KIND_WHITELIST;
        const bool allowed = whitelisted || (typed_.size() > 1 && !typedFound);
        const bool strong = whitelisted || ((first.kind & Dictionary::KIND_FLAG_APPROPRIATE_FOR_AUTOCORRECTION) &&
                                            normalizedScore(typed_, first.word, first.score) >= kAutocorrectThreshold);
        if (allowed && kind != Dictionary::KIND_SHORTCUT && strong) committed = strip.front();
      }
    }
    // Words typed right after a "." or a digit (".py", "3rd") are left as typed (#39).
    const char before = context_.empty() ? ' ' : context_.back();
    if (before == '.' || before == '/' || before == ':' || std::isdigit(static_cast<unsigned char>(before)))
      committed = typed;
    for (auto &w : strip) w = withCase(w, typed_);
    committed = withCase(committed, typed_);
    // The typed word is always there to pick (and learn), after the correction when there is one.
    correction_ = committed != typed;
    if (correction_) strip_.push_back(committed);
    strip_.push_back(typed);
    for (const auto &w : strip)
      if (std::find(strip_.begin(), strip_.end(), w) == strip_.end() && w != typed) strip_.push_back(w);
  }

  std::string decision() const { return correction_ ? strip_.front() : utf8(typed_); }

  void commitTyped() {
    if (typed_.empty()) return;
    const std::string typed = utf8(typed_);
    resetWord();
    commit_ += typed;
    context_ += typed;
  }

  // Commits WORD in place of the typed letters and learns it; PICKED: the user tapped it.
  void commitWord(const std::string &word, bool picked) {
    learn(word, picked);
    resetWord();
    commit_ += word;
    context_ += word;
  }

  // As AOSP's DictionaryFacilitator.addWordToUserHistory: a word typed at the start of a sentence is learned
  // in lower case unless only its capitalised form is a word; a word the dictionaries don't know counts as
  // valid once it was picked, else after it was typed a few times (the forgetting curve's levels); offensive
  // words aren't learned.
  void learn(const std::string &word, bool picked) {
    if (!learning_ || !history_ || !main_ || word.empty() || codePoints(word).size() >= size_t(kMaxWordLength)) return;
    if (main_->offensive(word) || main_->offensive(lowerCaseWord(word))) return;
    std::string learned = word;
    const auto end = context_.find_last_not_of(" ");
    const bool sentenceStart = end == std::string::npos || std::string(".!?\n").find(context_[end]) != std::string::npos;
    const bool known = main_->has(word) || history_->has(word);
    if (sentenceStart && (main_->has(lowerCaseWord(word)) || !known)) learned = lowerCaseWord(word);
    const auto cps = codePoints(learned);
    const auto context = ngramContext(context_);
    history_->dict->updateEntriesForWordWithNgramContext(&context, latinime::CodePointArrayView(cps), known || picked,
                                                         latinime::HistoricalInfo(int(std::time(nullptr)), 0, 1));
  }

  void resetWord() {
    typed_.clear(), xs_.clear(), ys_.clear(), strip_.clear();
    correction_ = false;
  }

  void dropLastChar() {
    if (context_.empty()) return;
    size_t n = context_.size() - 1;
    while (n > 0 && (context_[n] & 0xc0) == 0x80) n--;
    context_.erase(n);
  }

  // The text before the cursor changed: next words for it are asked for once nothing is typed after a space.
  void changed() {
    std::lock_guard g(mutex_);
    gen_++;
    next_.clear();
    if (field_ != Field::Text || !typed_.empty() || !(context_.empty() || context_.back() == ' ')) return;
    nextWanted_ = {context_, gen_};
    if (model_ready_) wake_.notify_all();
  }

  void loadModel() {
    std::lock_guard g(mutex_);
    if (loadAsked_ || paths_.model.empty()) return;
    loadAsked_ = true;
    wake_.notify_all();
  }

  void work() {
    std::unique_lock l(mutex_);
    for (;;) {
      wake_.wait(l, [&] { return stop_ || (loadAsked_ && !loadTried_) || (nextWanted_ && model_ready_); });
      if (stop_) return;
      if (loadAsked_ && !loadTried_) {
        loadTried_ = true;
        l.unlock();
        try {
          auto model = std::make_unique<sebtype_lm::Model>(paths_.model, 1);
          std::lock_guard g(modelMutex_);
          model_ = std::move(model);
          model_ready_ = true;
        } catch (const std::exception &e) {
          std::fprintf(stderr, "sebtype: %s\n", e.what());
        }
        l.lock();
        continue;
      }
      const auto [context, gen] = *std::exchange(nextWanted_, std::nullopt);
      l.unlock();
      std::vector<sebtype_lm::Word> words;
      {
        std::lock_guard g(modelMutex_);
        words = model_->nextWords(context, kNextWords);
      }
      l.lock();
      if (gen != gen_) continue;
      next_ = std::move(words);
      nextGen_ = gen;
      l.unlock();
      if (ready_) ready_();
      l.lock();
    }
  }

  EnglishPaths paths_;
  std::function<void()> ready_;
  std::unique_ptr<Lexicon> main_, history_;
  Layout layout_;
  std::unique_ptr<latinime::ProximityInfo> keys_;
  Field field_ = Field::Text;
  bool learning_ = true;

  std::vector<int> typed_, xs_, ys_;  // the letters typed and their touch points
  std::string context_;               // the text before them
  std::vector<std::string> strip_;
  bool correction_ = false;  // strip_[0] is what a space commits instead of the typed word
  bool domains_ = false;     // the list is e-mail domains
  bool afterPick_ = false;   // the last thing done was a pick and its space
  std::string commit_;
  Edit edit_;

  // The worker thread's: the model, loaded once, and the next words for the text at gen_.
  std::thread worker_;
  std::mutex mutex_, modelMutex_;
  std::condition_variable wake_;
  bool stop_ = false, loadAsked_ = false, loadTried_ = false;
  std::atomic<bool> model_ready_ = false;
  std::unique_ptr<sebtype_lm::Model> model_;
  uint64_t gen_ = 0, nextGen_ = ~uint64_t{0};
  std::optional<std::pair<std::string, uint64_t>> nextWanted_;
  std::vector<sebtype_lm::Word> next_;
};

}  // namespace

std::unique_ptr<Engine> makeEnglish(const EnglishPaths &paths, std::function<void()> ready) {
  return std::make_unique<English>(paths, std::move(ready));
}

}  // namespace sebtype
