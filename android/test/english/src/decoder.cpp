#include "decoder.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <fstream>
#include <sstream>
#include <stdexcept>

#include "fake_jni.h"

namespace harness {
namespace {

using fakejni::Arr;
using fakejni::ObjArr;
using fakejni::Str;

constexpr int MAX_WORD_LENGTH = 48;
constexpr int MAX_PREV_WORDS = 3;
constexpr int GRID_WIDTH = 32, GRID_HEIGHT = 16;  // config_keyboard_grid_width / height
constexpr int MAX_PROXIMITY_CHARS = 16;
constexpr float SEARCH_DISTANCE = 1.2f;
// touch_position_correction_data_holo: per row, the y offset and the sweet spot radius (x is unused).
constexpr float CORRECTION_Y[] = {-0.0005677f, 0.0381731f, 0.0880847f};
constexpr float CORRECTION_RADIUS[] = {0.1577026f, 0.1529972f, 0.1522819f};
constexpr float DEFAULT_CORRECTION_RADIUS = 0.15f;

template <class F>
F native(const std::string &package, const std::string &cls, const std::string &name) {
    return reinterpret_cast<F>(fakejni::method(package + "/" + cls + "." + name));
}

Arr<jint> ints(const std::vector<int> &v) {
    Arr<jint> a;
    a.v.assign(v.begin(), v.end());
    return a;
}
// The sets are ASCII, but the decoders suggest words such as "olé", so words go to and from UTF-8.
Arr<jint> codePoints(const std::string &s) {
    std::vector<int> v;
    for (size_t i = 0; i < s.size();) {
        const unsigned char c = s[i];
        const int n = c < 0x80 ? 1 : c < 0xe0 ? 2 : c < 0xf0 ? 3 : 4;
        int cp = n == 1 ? c : c & (0x3f >> (n - 1));
        for (int k = 1; k < n; k++) cp = cp << 6 | (s[i + k] & 0x3f);
        v.push_back(cp);
        i += n;
    }
    return ints(v);
}

void appendUtf8(std::string &s, int cp) {
    if (cp < 0x80) {
        s += char(cp);
    } else if (cp < 0x800) {
        s += char(0xc0 | cp >> 6);
        s += char(0x80 | (cp & 0x3f));
    } else if (cp < 0x10000) {
        s += char(0xe0 | cp >> 12);
        s += char(0x80 | (cp >> 6 & 0x3f));
        s += char(0x80 | (cp & 0x3f));
    } else {
        s += char(0xf0 | cp >> 18);
        s += char(0x80 | (cp >> 12 & 0x3f));
        s += char(0x80 | (cp >> 6 & 0x3f));
        s += char(0x80 | (cp & 0x3f));
    }
}

struct Key {
    int code, x, y, w, h;
};

std::vector<Key> readLayout(const std::string &path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("can't read " + path);
    std::vector<Key> keys;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream f(line);
        std::string name;
        Key k{};
        f >> name >> k.x >> k.y >> k.w >> k.h;
        // Function keys have negative codes, so the proximity info leaves them out, as the app does.
        k.code = name == "space" ? ' ' : name.size() == 1 ? name[0] : -1;
        keys.push_back(k);
    }
    return keys;
}

}  // namespace

long long makeProximityInfo(const std::string &package, const std::string &layoutPath) {
    std::vector<Key> keys;
    int width = 0, height = 0;
    for (const Key &k : readLayout(layoutPath)) {
        width = std::max(width, k.x + k.w);
        height = std::max(height, k.y + k.h);
        if (k.code >= ' ') keys.push_back(k);
    }
    const int keyWidth = 108, keyHeight = 160;  // the most common key size
    const int cellW = (width + GRID_WIDTH - 1) / GRID_WIDTH, cellH = (height + GRID_HEIGHT - 1) / GRID_HEIGHT;
    const int threshold = int(keyWidth * SEARCH_DISTANCE);

    std::vector<int> proximity(GRID_WIDTH * GRID_HEIGHT * MAX_PROXIMITY_CHARS, -1);
    for (int cell = 0; cell < GRID_WIDTH * GRID_HEIGHT; cell++) {
        const int cx = (cell % GRID_WIDTH) * cellW + cellW / 2, cy = (cell / GRID_WIDTH) * cellH + cellH / 2;
        int n = 0;
        for (const Key &k : keys) {
            const int dx = cx - std::clamp(cx, k.x, k.x + k.w), dy = cy - std::clamp(cy, k.y, k.y + k.h);
            if (dx * dx + dy * dy < threshold * threshold && n < MAX_PROXIMITY_CHARS)
                proximity[cell * MAX_PROXIMITY_CHARS + n++] = k.code;
        }
    }

    Arr<jint> prox = ints(proximity), xs, ys, ws, hs, codes;
    Arr<jfloat> sx, sy, sr;
    for (const Key &k : keys) {
        xs.v.push_back(k.x), ys.v.push_back(k.y), ws.v.push_back(k.w), hs.v.push_back(k.h);
        codes.v.push_back(k.code);
        const int row = k.y / keyHeight;
        const float diagonal = std::hypot(float(k.w), float(k.h));
        sx.v.push_back(k.x + k.w / 2.0f);
        sy.v.push_back(k.y + k.h / 2.0f + (row < 3 ? CORRECTION_Y[row] * k.h : 0));
        sr.v.push_back(row < 3 ? CORRECTION_RADIUS[row] * diagonal
                               : DEFAULT_CORRECTION_RADIUS * std::hypot(float(keyWidth), float(keyHeight)));
    }
    auto set = native<jlong (*)(JNIEnv *, jclass, jint, jint, jint, jint, jint, jint, jintArray, jint, jintArray,
                                jintArray, jintArray, jintArray, jintArray, jfloatArray, jfloatArray, jfloatArray)>(
        package, "keyboard/ProximityInfo", "setProximityInfoNative");
    return set(fakejni::env(), nullptr, width, height, GRID_WIDTH, GRID_HEIGHT, keyWidth, keyHeight,
               fakejni::ints(prox), int(keys.size()), fakejni::ints(xs), fakejni::ints(ys), fakejni::ints(ws),
               fakejni::ints(hs), fakejni::ints(codes), fakejni::floats(sx), fakejni::floats(sy),
               fakejni::floats(sr));
}

void addResult(std::vector<Word> &results, const Word &w, size_t capacity) {
    // Java's length() in UTF-16 units: the words are in the Basic Multilingual Plane, so code points.
    auto length = [](const std::string &s) {
        return std::count_if(s.begin(), s.end(), [](char c) { return (c & 0xc0) != 0x80; });
    };
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
    if (at == results.end()) return;  // worse than the last one
    if (!duplicate) results.insert(at, w);
    results.pop_back();  // SuggestionResults drops its last word even when the new one was a duplicate
}

PrevWords prevWords(const std::string &context) {
    PrevWords p;
    std::string line = context.substr(context.rfind('\n') == std::string::npos ? 0 : context.rfind('\n') + 1);
    std::vector<std::string> words;
    std::istringstream in(line);
    for (std::string w; in >> w;) words.push_back(w);
    for (int i = 0; i < MAX_PREV_WORDS; i++) {
        const int at = int(words.size()) - 1 - i;
        if (at < 0) {
            p.words.push_back(""), p.beginningOfSentence.push_back(true);
            break;
        }
        const char last = words[at].back();
        if (last == '.' || last == '!' || last == '?') {
            p.words.push_back(""), p.beginningOfSentence.push_back(true);
            break;
        }
        if (!std::isalnum(static_cast<unsigned char>(last)) && last != '\'') break;
        p.words.push_back(words[at]), p.beginningOfSentence.push_back(false);
    }
    return p;
}

Decoder::Decoder(const std::string &package, int maxResults, const std::string &dictPath, long long proximityInfo)
    : mPackage(package), mMaxResults(maxResults), mProximityInfo(proximityInfo) {
    std::ifstream f(dictPath, std::ios::binary | std::ios::ate);
    if (!f) throw std::runtime_error("can't read " + dictPath);
    const long long size = f.tellg();
    JNIEnv *env = fakejni::env();
    Str path, locale;
    path.s = dictPath;
    locale.s = "en_US";
    mDict = native<jlong (*)(JNIEnv *, jclass, jstring, jlong, jlong, jboolean)>(
        package, "latin/BinaryDictionary", "openNative")(env, nullptr, fakejni::str(path), 0, size, JNI_FALSE);
    if (!mDict) throw std::runtime_error("the decoder can't open " + dictPath);
    mSession = native<jlong (*)(JNIEnv *, jclass, jstring, jlong)>(
        package, "latin/DicTraverseSession", "setDicTraverseSessionNative")(env, nullptr, fakejni::str(locale), size);
    native<void (*)(JNIEnv *, jclass, jlong, jlong, jintArray, jint)>(
        package, "latin/DicTraverseSession", "initDicTraverseSessionNative")(env, nullptr, mSession, mDict, nullptr, 0);
}

std::vector<Word> Decoder::suggest(const Item &item) const {
    const std::string &typed = item.typed;
    if (typed.size() >= MAX_WORD_LENGTH) return {};
    Arr<jint> xs = ints(item.xs), ys = ints(item.ys);
    Arr<jint> times = ints(std::vector<int>(typed.size(), 0)), pointerIds = times;
    Arr<jint> input = ints(std::vector<int>(MAX_WORD_LENGTH, -1));  // NOT_A_CODE
    std::copy(typed.begin(), typed.end(), input.v.begin());
    // Options: not a gesture, no full edit distance, offensive words blocked (the default), weight 1.0.
    Arr<jint> options = ints({0, 0, 1, 0, 1000});

    const PrevWords prev = prevWords(item.context);
    std::vector<Arr<jint>> prevArrays(MAX_PREV_WORDS);
    ObjArr prevWordArrays;
    Arr<jboolean> bos;
    for (int i = 0; i < MAX_PREV_WORDS; i++) {
        if (size_t(i) < prev.words.size()) prevArrays[i] = codePoints(prev.words[i]);
        prevWordArrays.v.push_back(&prevArrays[i]);
        bos.v.push_back(size_t(i) < prev.beginningOfSentence.size() && prev.beginningOfSentence[i]);
    }

    Arr<jint> count = ints({0}), outCodePoints = ints(std::vector<int>(MAX_WORD_LENGTH * mMaxResults, 0));
    Arr<jint> scores = ints(std::vector<int>(mMaxResults, 0)), spaces = scores, types = scores;
    Arr<jint> confidence = ints({0});
    Arr<jfloat> weight;
    weight.v = {-1.0f};  // NOT_A_WEIGHT_OF_LANG_MODEL_VS_SPATIAL_MODEL
    native<void (*)(JNIEnv *, jclass, jlong, jlong, jlong, jintArray, jintArray, jintArray, jintArray, jintArray,
                    jint, jintArray, jobjectArray, jbooleanArray, jint, jintArray, jintArray, jintArray, jintArray,
                    jintArray, jintArray, jfloatArray)>(mPackage, "latin/BinaryDictionary", "getSuggestionsNative")(
        fakejni::env(), nullptr, mDict, mProximityInfo, mSession, fakejni::ints(xs), fakejni::ints(ys),
        fakejni::ints(times), fakejni::ints(pointerIds), fakejni::ints(input), int(typed.size()),
        fakejni::ints(options), fakejni::objs(prevWordArrays), fakejni::bools(bos), MAX_PREV_WORDS,
        fakejni::ints(count), fakejni::ints(outCodePoints), fakejni::ints(scores), fakejni::ints(spaces),
        fakejni::ints(types), fakejni::ints(confidence), fakejni::floats(weight));

    std::vector<Word> words;
    for (int j = 0; j < count.v[0]; j++) {
        std::string w;
        for (int k = 0; k < MAX_WORD_LENGTH && outCodePoints.v[j * MAX_WORD_LENGTH + k]; k++)
            appendUtf8(w, outCodePoints.v[j * MAX_WORD_LENGTH + k]);
        if (!w.empty()) words.push_back({w, scores.v[j], types.v[j]});
    }
    return words;
}

float Decoder::normalizedScore(const std::string &typed, const std::string &word, int score) const {
    Arr<jint> before = codePoints(typed), after = codePoints(word);
    return native<jfloat (*)(JNIEnv *, jclass, jintArray, jintArray, jint)>(
        mPackage, "latin/utils/BinaryDictionaryUtils", "calcNormalizedScoreNative")(
        fakejni::env(), nullptr, fakejni::ints(before), fakejni::ints(after), score);
}

}  // namespace harness
