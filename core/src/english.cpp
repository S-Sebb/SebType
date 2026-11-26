// SebType core: English on the phone (#244). Pristine AOSP LatinIME's decoder (engines/latinime, Apache-2.0)
// finds the words near the letters typed and keeps the learned words; SebType's model (engines/sebtype-lm)
// ranks them, decides what a space corrects and predicts the next words. MIT, SebType.
//
// Threads: keys and the decoder run on the caller's thread, as every engine's keys do. The model loads on a
// worker thread once the first letter is typed (Decisions #2, 2026-11-11: until then the decoder decides
// alone). A letter's key only types it, so the frontend can show it at once, as AOSP's keyboard does; the
// decoder runs in settle(), which the frontend calls next, and the worker then ranks its words with the
// model and posts the model's strip back through READY, as it does the next words (plan §3, #310). A space
// that comes while that ranking is pending waits for it, up to kRankWait, but only when the rankings timed
// so far say it will come within that; otherwise the decoder's rule decides at once.
#include <sebtype/hosts.h>

#include <jni.h>
#include <sys/stat.h>

#include <algorithm>
#include <chrono>
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
#include "dictionary/property/unigram_property.h"
#include "dictionary/structure/dictionary_structure_with_buffer_policy_factory.h"
#include "dictionary/utils/dict_file_writing_utils.h"
#include "dictionary/utils/file_utils.h"
#include "sebtype_lm.h"
#include "suggest/core/dictionary/dictionary.h"
#include "suggest/core/layout/proximity_info.h"
#include "suggest/core/result/suggestion_results.h"
#include "suggest/core/session/dic_traverse_session.h"
#include "suggest/core/suggest_options.h"
#include "trace.h"
#include "unicode.h"  // llama.cpp's Unicode tables (its src/)
#include "utils/autocorrection_threshold_utils.h"

namespace sebtype {
namespace {

using latinime::Dictionary;

constexpr int kMaxWordLength = MAX_WORD_LENGTH;  // AOSP's: longer words get no suggestions
constexpr int kMaxResults = MAX_RESULTS;          // the decoder's results per call (AOSP's 18)
constexpr int kPrevWords = MAX_PREV_WORD_COUNT_FOR_N_GRAM;
// AOSP's "modest" autocorrection, the rule until the model has loaded (Suggest.getSuggestedWordsForNonBatchInput).
constexpr float kAutocorrectThreshold = 0.185f;
// AOSP's double-space period timeout (config_double_space_period_timeout)
constexpr std::chrono::milliseconds kDoubleSpace{1100};
// AOSP's user dictionary frequency scale: a word added by hand (250) gets 160 (UserBinaryDictionary).
constexpr int kHandAddedFrequency = 250, kPersonalProbability = 160, kShortcutProbability = 14;
constexpr size_t kNextWords = 5;      // the model's next words asked for; blocked ones leave the list
constexpr size_t kContextChars = 1000;  // the text before the cursor kept; the model reads 300 of it
// How long a space waits for the model's ranking of the word before the decoder's rule decides (#310).
constexpr std::chrono::milliseconds kRankWait{400};
// How long the list shown waits for the model's after a key, so it changes once (#450): the phone's rankings
// and next words take 12-56 ms at p95, on the little cores too (docs/perf/2026-11-19-english-little-cores.md).
constexpr std::chrono::milliseconds kHold{100};
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

// The phantom space a revert took, as today's app puts it back (InputLogic's handleNonSeparatorEvent and
// handleSeparatorEvent, with its English spacing-and-punctuations/default.xml): before any character but its
// word separators, the word connector (') and Unicode's other symbols (those on our keys: © ® ° ™), and
// before a double quote that opens one. It stays for the next character after .,;:!?)]}.
bool spaceBeforeAfterRevert(char32_t c) {
  return c != '\'' && std::u32string_view(U"\t\n \u00a0()[]{}*&<>+=|.,;:!?/_\"-#$`\\%\u00bf\u00a1\u2014\u2013\u201e\u201c"
                                          U"\u201d\u00ab\u00bb\u2039\u203a\u2026\u061f\u060c\u061b~\u00a9\u00ae\u00b0\u2122")
                          .find(c) == std::u32string_view::npos;
}
bool keepsPhantomSpace(char32_t c) { return std::u32string_view(U".,;:!?)]}").find(c) != std::u32string_view::npos; }

// Whether TEXT (before the cursor) ends inside a double quote or after a digit: today's StringUtils's
// isInsideDoubleQuoteOrAfterDigit, where a double quote gets no phantom space.
bool insideQuoteOrAfterDigit(const std::string &text) {
  const auto cps = codePoints(text);
  if (cps.empty()) return false;
  if (cps.back() >= '0' && cps.back() <= '9') return true;
  // Java's Character.isWhitespace and isLetter, as today's app asks: the space separators but the no-break
  // ones, and the controls it counts; letters by llama.cpp's tables (\p{L}, Java's letters too).
  const auto space = [](int c) {
    return (c >= 0x09 && c <= 0x0d) || (c >= 0x1c && c <= 0x20) || c == 0x1680 || (c >= 0x2000 && c <= 0x2006) ||
           (c >= 0x2008 && c <= 0x200a) || c == 0x2028 || c == 0x2029 || c == 0x205f || c == 0x3000;
  };
  const auto letter = [](int c) { return unicode_cpt_flags_from_cpt(uint32_t(c)).is_letter; };
  int prev = 0, quotes = 0;
  for (size_t i = cps.size(); i-- > 0;) {
    const int c = cps[i];
    if (c == '"') {
      quotes++;
      if (space(prev)) return false;  // a closing quote
    } else if (c == '\n') break;
    if (space(c) && prev == '"') return true;              // an opening quote
    if (letter(c) && prev == '"') return false;  // a closing one
    prev = c;
  }
  return quotes % 2 == 1;
}

// Whether CPS, two letters or more, are all capitals (DONT, I'LL; not I, 42 or a word in small letters).
bool inCapitals(const std::vector<int> &cps) {
  return cps.size() > 1 && std::all_of(cps.begin(), cps.end(), [](int c) { return char32_t(c) == upperCase(c); }) &&
         std::any_of(cps.begin(), cps.end(), [](int c) { return char32_t(c) != lowerCase(c); });
}

std::string withCase(const std::string &word, const std::vector<int> &typed) {
  if (typed.empty() || char32_t(typed[0]) == lowerCase(typed[0])) return word;
  const bool allCaps = inCapitals(typed);
  auto cps = codePoints(word);
  // A word with capitals after its first letter keeps them unless typed in capitals: iPhone typed "Iphone"
  // where a sentence starts was IPhone (#568).
  if (!allCaps && std::any_of(cps.begin() + std::min<size_t>(1, cps.size()), cps.end(),
                              [](int c) { return char32_t(c) != lowerCase(c); }))
    return word;
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
    // As AOSP's: only the key right after a correction may undo it, and only the one after a reverted word
    // or the punctuation after it adds the space the revert took (its phantom space).
    const auto correction = std::exchange(lastCorrection_, std::nullopt);
    const bool phantom = std::exchange(phantomSpace_, false);
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
    leaveTail();
    if (k.sym == ks::BackSpace) {
      if (correction) return revert(*correction);
      if (typed_.empty()) {
        if (reopenBeforeDeleted()) return true;
        dropLastChar();
        changed();
        return false;
      }
      typed_.pop_back(), xs_.pop_back(), ys_.pop_back();
      typedChanged();
      return true;
    }
    if (isLetter(c) || ((c == '\'' || c == U'’') && !typed_.empty())) {
      if (phantom && c != '\'') {  // today's app's only word connector is ASCII's apostrophe
        if (!typed_.empty()) commitWord(utf8(typed_), false);
        commit_ += " ";
        context_ += " ";
      }
      if (typed_.empty()) loadModel();
      typed_.push_back(int(c));
      const auto [x, y] = k.x >= 0 ? std::pair{k.x, k.y} : keyCentre(lowerCase(c));
      xs_.push_back(x), ys_.push_back(y);
      typedChanged();
      return true;
    }
    if (k.sym == ks::Return || k.sym == ks::KP_Enter || k.sym == ks::Tab) {
      if (!typed_.empty()) commitWord(decision(), false);
      context_ += k.sym == ks::Tab ? "\t" : "\n";
      changed();
      return false;  // the frontend does the field's action or types it
    }
    if (c && isSeparator(c)) {
      const auto now = std::chrono::steady_clock::now();
      const auto lastSpace = std::exchange(lastSpace_, c == ' ' ? now : std::chrono::steady_clock::time_point{});
      // Two spaces after a word (or a space after a picked one): ". ", as AOSP's double-space period.
      if (c == ' ' && doubleSpacePeriod_ && typed_.empty() && (afterPick || now - lastSpace < kDoubleSpace) &&
          spaceEndsSentence()) {
        context_.pop_back();
        edit_.deleteBefore = 1;
        commit_ += ". ";
        context_ += ". ";
        lastSpace_ = {};
        changed();
        return true;
      }
      const bool quoteSpace = phantom && c == '"' && !insideQuoteOrAfterDigit(context_ + utf8(typed_));
      if (afterPick && joinsWord(c) && context_.ends_with(' ')) {
        // "word" picked, then ".": "word. " (#39); a space the user typed keeps the period where it is.
        context_.pop_back();
        edit_.deleteBefore = 1;
      } else if (!typed_.empty()) {
        Correction last{typed_, xs_, ys_, decision(), {}, utf8(c)};
        last.learned = commitWord(last.committed, false);
        if (last.committed != utf8(last.typed)) lastCorrection_ = std::move(last);
      }
      if (quoteSpace) commit_ += " ", context_ += " ";
      commit_ += utf8(c);
      context_ += utf8(c);
      if (edit_.deleteBefore) commit_ += " ", context_ += " ";
      phantomSpace_ = phantom && (keepsPhantomSpace(c) || c == '"' && !quoteSpace);
      changed();
      return true;
    }
    // Digits, symbols and the keys that move the cursor: the word stays as typed, and after a revert the space
    // it took comes back before a digit or a symbol, as in today's app.
    commitTyped();
    if (phantom && c && spaceBeforeAfterRevert(c)) commit_ += " ", context_ += " ";
    if (c) context_ += utf8(c);
    changed();
    return false;
  }

  bool settle() override {
    if (!decodePending_) return false;
    update();
    return true;
  }

  // The cursor moved inside the word (to a character from its start), as the frontend saw the user put it.
  void moveCursor(int chars) override {
    if (!typed_.empty()) tail_ = typed_.size() - std::clamp(size_t(std::max(chars, 0)), size_t{0}, typed_.size());
  }

  std::string takeCommit() override { return std::exchange(commit_, {}); }
  Edit takeEdit() override { return std::exchange(edit_, {}); }

  Preedit preedit() override {
    if (typed_.empty()) return {};
    const std::string text = utf8(typed_);
    return {{{text, true, false}}, int(utf8(std::vector(typed_.begin(), typed_.end() - tail_)).size())};
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
  // Of the list last shown: a ranking that came since is shown first (list() takes it).
  int highlighted() override { return shownCorrection_ ? 0 : -1; }

  // A tap picks from the list last shown, never from a ranking that came after it (#310).
  void selectAt(int index) override {
    const auto l = shown_;
    if (index < 0 || size_t(index) >= l.size()) return;
    // The list of a word committed since, kept until the next words come (#450): it can't replace that word.
    if (shownComposing_ && typed_.empty()) return;
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
    // A reopened word with a space after it in the field: the cursor goes after that space, not a second one
    if (after_.starts_with(' ')) after_.erase(0, 1), edit_.cursor = 1;
    else commit_ += " ";
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
  void applySettings(const Settings &s, bool learning) override {
    learning_ = learning;
    autocorrect_ = s.autocorrect;
    doubleSpacePeriod_ = s.doubleSpacePeriod;
    if (s.englishWords != personalWords_) {
      personalWords_ = s.englishWords;
      openPersonal();
    }
  }
  void setLayout(const Layout &layout) override {
    layout_ = layout;
    keys_ = proximityInfo(layout);
  }
  // A word the cursor touches is reopened, as AOSP's restartSuggestionsOnWordTouchedByCursor does.
  void setContext(const std::string &before, const std::string &after, bool selection) override {
    resetWord();
    context_ = before.size() > kContextChars ? before.substr(before.size() - kContextChars) : before;
    after_ = after;
    selection_ = selection;
    changed();
    if (!selection_ && reopen(0)) update();
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
  // The last word a separator corrected, until the next key (AOSP's LastComposedWord)
  struct Correction {
    std::vector<int> typed, xs, ys;
    std::string committed, learned, separator;
  };

  std::string historyPath() const { return paths_.userDir + "/en_history"; }

  // The personal dictionary's words as AOSP's user dictionary holds them: a dictionary of their own, made
  // again whenever they change (they come from the platform, which keeps them).
  void openPersonal() {
    personal_.reset();
    if (paths_.userDir.empty()) return;
    const std::string path = paths_.userDir + "/en_personal";
    latinime::FileUtils::removeDirAndFiles(path.c_str());
    if (personalWords_.empty()) return;
    latinime::DictionaryHeaderStructurePolicy::AttributeMap attributes;
    auto put = [&](const std::string &k, const std::string &v) { attributes[{k.begin(), k.end()}] = {v.begin(), v.end()}; };
    put("dictionary", "user.en_US");
    put("locale", "en_US");
    put("version", "1");
    const std::string locale = "en_US";
    latinime::DictFileWritingUtils::createEmptyDictFile(path.c_str(), 403, {locale.begin(), locale.end()}, &attributes);
    personal_ = Lexicon::open(path, 0, 0, true);
    if (!personal_) {
      std::fprintf(stderr, "sebtype: can't make the English personal words in %s\n", path.c_str());
      return;
    }
    // As AOSP's UserBinaryDictionary, a shortcut is an entry that is not a word, offering its words as
    // KIND_SHORTCUT candidates, which never autocorrect (below 15, a whitelist entry's). Each spelling is added
    // once, as a word if any personal word has it, with all the words it is a shortcut for: adding it again
    // would replace its entry, so a word that is also another's shortcut would stop being offered (#380).
    struct Entry {
      bool word = false;
      int probability = 0;
      std::vector<std::vector<int>> targets;
    };
    std::map<std::vector<int>, Entry> entries;
    auto valid = [](const std::vector<int> &cps) { return !cps.empty() && cps.size() < size_t(kMaxWordLength); };
    for (const PersonalWord &w : personalWords_) {
      const auto cps = codePoints(w.word);
      if (!valid(cps)) continue;
      const int probability = std::clamp(w.frequency * kPersonalProbability / kHandAddedFrequency, 1, 255);
      Entry &word = entries[cps];
      word.word = true;
      word.probability = std::max(word.probability, probability);
      const auto shortcut = codePoints(w.shortcut);
      if (!valid(shortcut)) continue;
      Entry &entry = entries[shortcut];
      entry.probability = std::max(entry.probability, probability);
      entry.targets.push_back(cps);
    }
    for (auto &[cps, e] : entries) {
      std::vector<latinime::UnigramProperty::ShortcutProperty> targets;
      for (auto &target : e.targets) targets.emplace_back(std::move(target), kShortcutProbability);
      const latinime::UnigramProperty unigram(false, !e.word, false, false, e.probability, latinime::HistoricalInfo(),
                                              std::move(targets));
      personal_->dict->addUnigramEntry(latinime::CodePointArrayView(cps), &unigram);
    }
  }

  // The text ends in a space after a word, a digit or a closing mark: a second space may make it ". ".
  bool spaceEndsSentence() const {
    if (context_.size() < 2 || context_.back() != ' ') return false;
    size_t at = context_.size() - 2;
    while (at > 0 && (context_[at] & 0xc0) == 0x80) at--;
    const auto cps = codePoints(context_.substr(at, context_.size() - 1 - at));
    const char32_t c = cps.empty() ? 0 : char32_t(cps.back());
    return isLetter(c) || (c >= '0' && c <= '9') || std::u32string_view(U")]}\"'").find(c) != std::u32string_view::npos;
  }

  // Today's app (FUTO Keyboard's, before #191 stage 6) keeps English's learned words in this same AOSP format,
  // in a folder of this name. The update moves that folder into userDir (android/app's Migration); its words
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
    if (!holding()) shown_ = currentList(), shownCorrection_ = correction_, shownComposing_ = !typed_.empty();
    return shown_;
  }
  // Whether the list shown stays as it is, so a key changes it once, to the model's list (#450): until
  // settle() decodes the letters typed, then until the model's ranking or next words come, while they are
  // expected within kHold. A model known to be slower shows the decoder's list or the dictionaries' first.
  bool holding() {
    if (!typed_.empty() && decodePending_) return true;
    if (!model_ready_) return false;
    std::lock_guard g(mutex_);
    if (!typed_.empty()) return rankPending_ && rankedGen_ != gen_ && expectedIn(rankTime_) <= kHold;
    return nextGen_ != gen_ && field_ == Field::Text && main_ && !atEmail() &&
           expectedIn(nextTime_) <= kHold;
  }
  // Whether a dictionary has WORD, the model's next word, as it is, in small letters, or with only its first
  // letter a capital: shown in capitals, I'M is the dictionary's I'm (#568).
  bool known(const std::string &word) const {
    const std::string small = lowerCaseWord(word);
    auto cps = codePoints(small);
    if (!cps.empty()) cps[0] = int(upperCase(cps[0]));
    for (const std::string &w : {word, small, utf8(cps)})
      if (main_->has(w) || (history_ && history_->has(w)) || (personal_ && personal_->has(w))) return true;
    return false;
  }

  std::vector<std::string> currentList() {
    if (!typed_.empty()) {
      takeRanking();
      return strip_;
    }
    domains_ = atEmail();
    if (domains_) return domains(afterAt());
    if (field_ != Field::Text || !main_) return {};
    std::vector<std::string> words;
    {
      std::lock_guard g(mutex_);
      // The model's next words are pieces it ran on to a word's end: one that no dictionary has ("Thank you
      // thank": youin) isn't offered (#568).
      if (nextGen_ == gen_)
        for (const auto &w : next_)
          if (known(w.word)) words.push_back(w.word);
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

  // The letters typed changed: the text before the cursor did, and the strip is the old one until settle().
  void typedChanged() {
    changed();
    decodePending_ = true;
    std::lock_guard g(mutex_);
    rankPending_ = false;
    rankWanted_.reset();
  }

  // The strip and the correction for the letters typed so far.
  void update() {
    decodePending_ = false;
    const std::string typed = utf8(typed_);
    correction_ = false, modelStrip_ = false;
    strip_.clear();
    // Right after "@" (an address typed in a text field): domains, never a correction.
    domains_ = !context_.empty() && context_.back() == '@';
    if (domains_) {
      strip_ = domains(typed);
      return;
    }
    if (!main_) return;
    const auto context = ngramContext(context_);
    std::vector<std::string> userWords;  // the user's words for the letters in either case, before the merge
    const auto suggest = [&](const std::vector<int> &letters) {
      std::vector<Word> out;
      for (const Word &w : main_->suggest(keys_.get(), letters, xs_, ys_, context)) addResult(out, w, kMaxResults);
      for (Lexicon *lexicon : {history_.get(), personal_.get()})
        if (lexicon)
          for (const Word &w : lexicon->suggest(keys_.get(), letters, xs_, ys_, context)) {
            addResult(out, w, kMaxResults);
            if (std::find(userWords.begin(), userWords.end(), w.word) == userWords.end()) userWords.push_back(w.word);
          }
      return out;
    };
    const std::vector<Word> results = suggest(typed_);

    // AOSP's rule: the typed word leaves the list, and whether it was there decides if it may be corrected.
    std::string committed = typed;
    std::vector<std::string> strip;
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
    show(strip, committed);
    // A word longer than the dictionary's words isn't ranked: as long as a pasted line, it overran the model's
    // batch and its decoding failed (#568).
    if (!model_ready_ || typed_.empty() || typed_.size() >= size_t(kMaxWordLength)) return;
    // The model's ranking comes from the worker; a key never waits for it.
    // A personal word's shortcut offers it first, as the FUTO-based app did (#380): the model would rank a
    // phrase it doesn't know last. That app put first the words of the shortcut typed, in any case, and a
    // shortcut's word the decoder ranks first, as for letters near one ("qvx" for "qvz"), and then a space
    // corrected nothing, as by AOSP's rule above. Those words stay out of the ranking, whichever dictionary
    // offers them; other shortcuts' words the model ranks like any other ("because" for "becaus" still
    // corrects with a shortcut "becuase").
    const auto lower = [](std::vector<int> cps) {
      for (int &c : cps) c = int(lowerCase(c));
      return cps;
    };
    const auto typedLower = lower(typed_);
    shortcuts_.clear();
    const auto add = [&](const std::string &word) {
      if (std::find(shortcuts_.begin(), shortcuts_.end(), word) == shortcuts_.end()) shortcuts_.push_back(word);
    };
    for (const PersonalWord &w : personalWords_)
      if (lower(codePoints(w.shortcut)) == typedLower) add(w.word);
    if (!results.empty() && (results.front().kind & Dictionary::KIND_MASK_KIND) == Dictionary::KIND_SHORTCUT)
      add(results.front().word);
    // The model ranks a word typed with capitals (Were where a sentence starts, ILL) from the decoder's words
    // for it in lower case, as the dictionary has them and as its shortcuts are found (cant: can't), and the
    // dictionary's word of those letters is the typed word; a space commits a word in the capitals typed (#568).
    const std::string typedLowerText = lowerCaseWord(typed);
    const std::vector<Word> lowered = typed != typedLowerText ? suggest(typedLower) : std::vector<Word>{};
    const std::vector<Word> &ranked = typed != typedLowerText ? lowered : results;
    // A word the dictionary lacks and the user's words have is learned, and a space keeps it: as typed ("Cant"
    // learned mid-sentence, though the dictionary has cant), or, if the dictionary lacks its lower case too, in
    // the capitals it was learned with, typed in any case: theyre learned at a sentence start and typed
    // "Theyre", or SebType typed "sebtype", as london is London. The user's words are asked themselves, not
    // the merged list, whose 18 words may leave it out ("dont" among don't's neighbours). A word typed once
    // isn't learned yet ("see x.tge"), and one learned only in capitals (PLEASE DONT) says little of how it is
    // spelt (#555, #568).
    const auto userHas = [&](const std::string &w) {
      return (history_ && history_->has(w)) || (personal_ && personal_->has(w));
    };
    const auto allCaps = [](const std::string &w) { return inCapitals(codePoints(w)); };
    std::string learned;
    if (!main_->has(typed)) {
      if (userHas(typed)) learned = typed;
      else if (!main_->has(typedLowerText))
        for (const std::string &w : userWords)
          if (lowerCaseWord(w) == typedLowerText && !allCaps(w) && userHas(w)) {
            learned = withCase(w, typed_);
            break;
          }
    }
    // A word with a stray capital inside it (iLl, ImPossible) that neither dictionary has, and whose small
    // letters are a word, is ranked in small letters, and a space gives it its first letter's case: as typed, no
    // word, it became a contraction ("I feel iLl": I'll), and read capitalised, "I feel Ill" was I'll too. Inner
    // capitals whose small letters aren't a word are meant (DeShawn, iCloud, camelCase) and stay (#568).
    const bool stray = std::any_of(typed_.begin() + 1, typed_.end(), [](int c) { return char32_t(c) != lowerCase(c); });
    const bool readSmall = learned.empty() && !main_->has(typed) && stray && !allCaps(typed) && main_->has(typedLowerText);
    const std::vector<int> cased = readSmall ? typedLower : typed_;
    const std::string word = learned.empty() ? utf8(cased) : learned;
    const auto has = [&](const std::string &w) {
      return std::any_of(ranked.begin(), ranked.end(), [&](const Word &r) { return r.word == w; });
    };
    Rank rank{context_, word, {}, false, !learned.empty(), 0};
    for (const Word &w : ranked) {
      const bool same = w.word == word || withCase(w.word, cased) == word;
      rank.typedIsWord |= same;
      if (std::find(shortcuts_.begin(), shortcuts_.end(), w.word) != shortcuts_.end()) continue;
      // A contraction's capitalised form beside its own isn't offered for it: shown in the case typed, it is
      // the same word, or one the text doesn't call for ("I said oclock": O'Clock).
      const std::string small = lowerCaseWord(w.word);
      if (!same && small != w.word && !allCaps(w.word) && small.find('\'') != std::string::npos && has(small))
        continue;
      rank.candidates.push_back({same ? word : w.word,
                                 normalizedScore(typed != typedLowerText ? typedLower : typed_, w.word, w.score)});
    }
    std::lock_guard g(mutex_);
    rank.gen = gen_;
    rankWanted_ = std::move(rank);
    rankPending_ = true;
    wake_.notify_all();
  }

  // Shows STRIP (best first) and COMMITTED, what a space commits, for the letters typed.
  void show(std::vector<std::string> strip, std::string committed) {
    const std::string typed = utf8(typed_);
    // With autocorrect off, and for words typed right after a "." or a digit (".py", "3rd", #39), the
    // word stays as typed.
    const char before = context_.empty() ? ' ' : context_.back();
    if (!autocorrect_ || resumed_ || before == '.' || before == '/' || before == ':' ||
        std::isdigit(static_cast<unsigned char>(before)))
      committed = typed;
    for (auto &w : strip) w = withCase(w, typed_);
    committed = withCase(committed, typed_);
    // The typed word is always there to pick (and learn), after the correction when there is one.
    strip_.clear();
    correction_ = committed != typed;
    if (correction_) strip_.push_back(committed);
    strip_.push_back(typed);
    for (const auto &w : strip)
      if (std::find(strip_.begin(), strip_.end(), w) == strip_.end() && w != typed) strip_.push_back(w);
  }

  // Shows the model's ranking of the letters typed once the worker has posted it.
  void takeRanking() {
    std::optional<sebtype_lm::Ranked> ranked;
    {
      std::lock_guard g(mutex_);
      ranked = posted();
    }
    if (ranked) showRanking(*ranked);
  }

  // As takeRanking, for a space about to commit the word: waits up to kRankWait for a ranking still pending.
  // Traced as a "SebType space" section, as long as the wait, holding an empty one named by what the space
  // found: the model's ranking "ready" or "waited" for, or the decoder's rule because the ranking was "late"
  // (the wait timed out), "skipped" (expected after kRankWait: no wait) or "none" (none asked: no model yet).
  void takeRankingForSpace() {
    TraceSection section("SebType space");
    const char *outcome;
    std::optional<sebtype_lm::Ranked> ranked;
    {
      std::unique_lock l(mutex_);
      if (!rankPending_) outcome = modelStrip_ ? "ready" : "none";
      else if (rankedGen_ == gen_) outcome = "ready";
      else if (expectedIn(rankTime_) > kRankWait) outcome = "skipped";
      else outcome = ranked_.wait_for(l, kRankWait, [&] { return rankedGen_ == gen_; }) ? "waited" : "late";
      ranked = posted();
    }
    if (ranked) showRanking(*ranked);
    TraceSection mark(outcome);
  }

  // The ranking the worker posted for the letters typed, if it is pending and has come; under mutex_.
  std::optional<sebtype_lm::Ranked> posted() {
    if (!rankPending_ || rankedGen_ != gen_) return std::nullopt;
    rankPending_ = false;
    return std::move(rankedWords_);
  }
  void showRanking(const sebtype_lm::Ranked &ranked) {
    auto strip = shortcuts_;
    strip.insert(strip.end(), ranked.strip.begin(), ranked.strip.end());
    show(strip, shortcuts_.empty() ? ranked.committed : utf8(typed_));
    modelStrip_ = true;
  }

  // How long until the ranking asked for at gen_ is expected to come, by the times the worker took so far:
  // what is left of the job it is on, and the ranking itself unless that is the job. A job past its time
  // is taken to need its time again: the worker is behind, so it is no sign of the ranking coming soon.
  // With nextTime_, the same for the next words. Under mutex_.
  std::chrono::steady_clock::duration expectedIn(std::chrono::steady_clock::duration time) const {
    using Duration = std::chrono::steady_clock::duration;
    const auto now = std::chrono::steady_clock::now();
    const Duration left = !busy_ ? Duration{} : busyUntil_ > now ? busyUntil_ - now : busyUntil_ - busyStart_;
    return busy_ && rankingGen_ == gen_ ? left : left + time;
  }

  std::string decision() {
    if (decodePending_) update();
    takeRankingForSpace();
    return correction_ ? strip_.front() : utf8(typed_);
  }

  void commitTyped() {
    leaveTail();
    if (typed_.empty()) return;
    const std::string typed = utf8(typed_);
    resetWord();
    commit_ += typed;
    context_ += typed;
  }

  // Commits WORD in place of the typed letters and learns it; PICKED: the user tapped it. Returns the
  // word as learned (empty: not learned).
  std::string commitWord(const std::string &word, bool picked) {
    std::string learned = learn(word, picked);
    resetWord();
    commit_ += word;
    context_ += word;
    return learned;
  }

  // As AOSP's DictionaryFacilitator.addWordToUserHistory: a word typed at the start of a sentence is learned
  // in lower case unless only its capitalised form is a word; a word the dictionaries don't know counts as
  // valid once it was picked, else after it was typed a few times (the forgetting curve's levels); offensive
  // words aren't learned.
  std::string learn(const std::string &word, bool picked) {
    if (!learning_ || !history_ || !main_ || word.empty() || codePoints(word).size() >= size_t(kMaxWordLength)) return {};
    if (main_->offensive(word) || main_->offensive(lowerCaseWord(word))) return {};
    std::string learned = word;
    const auto end = context_.find_last_not_of(" ");
    const bool sentenceStart = end == std::string::npos || std::string(".!?\n").find(context_[end]) != std::string::npos;
    const bool known = main_->has(word) || history_->has(word) || (personal_ && personal_->has(word));
    if (sentenceStart && (main_->has(lowerCaseWord(word)) || !known)) learned = lowerCaseWord(word);
    const auto cps = codePoints(learned);
    const auto context = ngramContext(context_);
    history_->dict->updateEntriesForWordWithNgramContext(&context, latinime::CodePointArrayView(cps), known || picked,
                                                         latinime::HistoricalInfo(int(std::time(nullptr)), 0, 1));
    return learned;
  }

  // Backspace right after a separator corrected a word: the word as typed again, as AOSP's revertCommit.
  // The correction is no longer learned. After a space the typed word is open again, never to be corrected,
  // and the space comes back before the next word (AOSP's phantom space); other punctuation stays after it.
  bool revert(const Correction &last) {
    if (history_ && !last.learned.empty())
      history_->dict->removeUnigramEntry(latinime::CodePointArrayView(codePoints(last.learned)));
    const std::string typed = utf8(last.typed);
    edit_.deleteBefore = int(codePoints(last.committed).size() + codePoints(last.separator).size());
    context_.erase(context_.size() - std::min(context_.size(), last.committed.size() + last.separator.size()));
    if (last.separator == " ") {
      typed_ = last.typed, xs_ = last.xs, ys_ = last.ys;
      resumed_ = phantomSpace_ = true;
      typedChanged();
    } else {
      commit_ += typed + last.separator;
      context_ += typed + last.separator;
      changed();
    }
    return true;
  }

  // Opens the word the cursor touches again, after DELETED characters (not letters) went before the cursor:
  // the composing text takes them and the word's letters on both sides of the cursor, as they are in the
  // field. A reopened word is never corrected (AOSP's resumed words).
  bool reopen(int deleted) {
    if (field_ != Field::Text || !main_) return false;
    // The letters (and apostrophes inside them) before the cursor and after it
    auto isPart = [](char32_t c) { return isLetter(c) || c == '\'' || c == U'’'; };
    const auto before = codePoints(context_.substr(context_.size() - std::min(context_.size(), size_t(4 * kMaxWordLength))));
    auto start = before.end();
    while (start != before.begin() && isPart(start[-1])) --start;
    std::vector<int> word(start, before.end());
    const auto afterCps = codePoints(after_.substr(0, 4 * kMaxWordLength));
    auto end = afterCps.begin();
    while (end != afterCps.end() && isPart(*end)) ++end;
    while (end != afterCps.begin() && !isLetter(end[-1])) --end;
    word.insert(word.end(), afterCps.begin(), end);
    const size_t leading = std::find_if(word.begin(), word.end(), [](int c) { return isLetter(c); }) - word.begin();
    const size_t tail = end - afterCps.begin(), head = word.size() - tail;
    // No word, or apostrophes before it reaching past the cursor
    if (leading == word.size() || leading > head || word.size() >= size_t(kMaxWordLength)) return false;
    word.erase(word.begin(), word.begin() + leading);
    context_.erase(context_.size() - utf8(word).size() + utf8(std::vector(word.end() - tail, word.end())).size());
    after_.erase(0, utf8(std::vector(afterCps.begin(), end)).size());
    edit_.recompose = true;
    edit_.composeBefore = int(head - leading) + deleted;
    edit_.composeAfter = int(tail);
    typed_ = word;
    for (int c : word) {
      const auto [x, y] = keyCentre(lowerCase(c));
      xs_.push_back(x), ys_.push_back(y);
    }
    tail_ = tail;
    resumed_ = true;
    loadModel();
    typedChanged();
    return true;
  }

  // Backspace with nothing typed: when it takes a space or a punctuation mark and leaves the cursor at the
  // end of a word, the word opens again (AOSP restarts suggestions after a delete).
  bool reopenBeforeDeleted() {
    if (selection_ || context_.size() < 2 || (!after_.empty() && isLetter(codePoints(after_.substr(0, 4))[0]))) return false;
    const unsigned char last = context_.back();
    if (last >= 0x80 || isLetter(last) || last == '\'') return false;
    context_.pop_back();
    if (reopen(1)) return true;
    context_ += char(last);
    return false;
  }

  // The cursor is inside a reopened word: a key acts at the cursor, on the letters before it (AOSP's
  // resetComposingWord); the rest stays in the field as it is.
  void leaveTail() {
    if (!tail_) return;
    after_.insert(0, utf8(std::vector(typed_.end() - tail_, typed_.end())));
    typed_.resize(typed_.size() - tail_), xs_.resize(typed_.size()), ys_.resize(typed_.size());
    tail_ = 0;
    edit_.recompose = true;
    edit_.composeBefore = int(typed_.size());
    edit_.composeAfter = 0;
    if (typed_.empty()) resetWord();
    else typedChanged();
  }

  void resetWord() {
    typed_.clear(), xs_.clear(), ys_.clear(), strip_.clear();
    correction_ = false, decodePending_ = false, resumed_ = false, phantomSpace_ = false;
    tail_ = 0;
    lastCorrection_.reset();
    std::lock_guard g(mutex_);
    rankPending_ = false;
    rankWanted_.reset();
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

  // The worker starts a job that took TIME before (RANKING: the gen it ranks) and ends it; under mutex_.
  std::chrono::steady_clock::time_point begin(std::chrono::steady_clock::duration time, uint64_t ranking) {
    const auto now = std::chrono::steady_clock::now();
    busy_ = true, busyStart_ = now, busyUntil_ = now + time, rankingGen_ = ranking;
    return now;
  }
  void end(std::chrono::steady_clock::duration &time, std::chrono::steady_clock::time_point start) {
    busy_ = false;
    // The last two jobs' times weighed alike: a word's rankings take about as long as each other.
    const auto took = std::chrono::steady_clock::now() - start;
    time = time.count() ? (time + took) / 2 : took;
  }

  void work() {
    std::unique_lock l(mutex_);
    for (;;) {
      wake_.wait(l, [&] { return stop_ || (loadAsked_ && !loadTried_) || ((rankWanted_ || nextWanted_) && model_ready_); });
      if (stop_) return;
      if (loadAsked_ && !loadTried_) {
        loadTried_ = true;
        l.unlock();
        try {
          TraceSection section("SebType load");
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
      if (rankWanted_) {  // the word being typed first: a space may be waiting for it
        const Rank r = *std::exchange(rankWanted_, std::nullopt);
        const auto start = begin(rankTime_, r.gen);
        l.unlock();
        sebtype_lm::Ranked ranked;
        {
          TraceSection section("SebType rank");
          std::lock_guard g(modelMutex_);
          ranked = sebtype_lm::rank(*model_, r.context, r.typed, r.candidates, r.typedIsWord, r.typedIsLearned);
        }
        std::this_thread::sleep_for(paths_.rankDelay);
        l.lock();
        end(rankTime_, start);
        if (r.gen != gen_) continue;
        rankedWords_ = std::move(ranked);
        rankedGen_ = r.gen;
        ranked_.notify_all();
        l.unlock();
        if (ready_) ready_();
        l.lock();
        continue;
      }
      const auto [context, gen] = *std::exchange(nextWanted_, std::nullopt);
      if (gen != gen_) continue;  // typed on meanwhile
      const auto start = begin(nextTime_, ~uint64_t{0});
      l.unlock();
      std::vector<sebtype_lm::Word> words;
      {
        TraceSection section("SebType next");
        std::lock_guard g(modelMutex_);
        words = model_->nextWords(context, kNextWords);
      }
      l.lock();
      end(nextTime_, start);
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
  std::unique_ptr<Lexicon> main_, history_, personal_;
  std::vector<PersonalWord> personalWords_;
  Layout layout_;
  std::unique_ptr<latinime::ProximityInfo> keys_;
  Field field_ = Field::Text;
  bool learning_ = true;
  bool autocorrect_ = true, doubleSpacePeriod_ = false;
  std::chrono::steady_clock::time_point lastSpace_;  // the last space typed, for the double-space period

  std::vector<int> typed_, xs_, ys_;  // the letters typed and their touch points
  std::string context_;               // the text before them
  std::vector<std::string> strip_;
  std::vector<std::string> shortcuts_;  // the personal words the letters typed are a shortcut for
  bool correction_ = false;  // strip_[0] is what a space commits instead of the typed word
  bool modelStrip_ = false;  // strip_ is the model's ranking, not the decoder's rule
  bool domains_ = false;     // the list is e-mail domains
  bool afterPick_ = false;   // the last thing done was a pick and its space
  std::optional<Correction> lastCorrection_;  // the last word a separator corrected, until the next key
  bool phantomSpace_ = false;  // a revert took a space that the next word puts back
  bool resumed_ = false;       // the word typed was reopened: never corrected
  size_t tail_ = 0;            // the letters of typed_ after the cursor
  std::string after_;          // the start of the text after the cursor
  bool selection_ = false;     // text is selected
  bool decodePending_ = false;  // the letters typed changed since the strip was made
  std::vector<std::string> shown_;  // the list last returned, which a tap picks from
  bool shownCorrection_ = false;    // shown_[0] is what a space commits instead of the typed word
  bool shownComposing_ = false;     // shown_ was made for a word being typed
  std::string commit_;
  Edit edit_;

  // The worker thread's: the model, loaded once, the next words for the text at gen_ and the ranking of
  // the letters typed at gen_ (rankPending_: asked for and not shown yet).
  struct Rank {
    std::string context, typed;
    std::vector<sebtype_lm::Candidate> candidates;
    bool typedIsWord;
    bool typedIsLearned;  // only the learned or personal words have it, so the model never corrects it (#555)
    uint64_t gen;
  };
  std::thread worker_;
  std::mutex mutex_, modelMutex_;
  std::condition_variable wake_, ranked_;
  std::optional<Rank> rankWanted_;
  sebtype_lm::Ranked rankedWords_;
  uint64_t rankedGen_ = ~uint64_t{0};
  bool rankPending_ = false;
  // The worker's job, for a space deciding whether to wait (expectedIn)
  bool busy_ = false;
  std::chrono::steady_clock::time_point busyStart_, busyUntil_;
  uint64_t rankingGen_ = ~uint64_t{0};
  std::chrono::steady_clock::duration rankTime_{}, nextTime_{};
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
