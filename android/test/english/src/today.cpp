// Today's English stack: FUTO's decoder and transformer (ml4_q6_k.gguf), built in place from
// android/app/src/main/cpp, with a fresh install's settings (autocorrect "modest", transformer on, no learned
// or personal words).
//
// The JNI calls go to FUTO's native code unchanged. What the app's Kotlin and Java do around them is restated
// here so the harness measures what the keyboard commits and shows: LanguageModel.kt (context trimming, the
// model's autocorrect verdict), LanguageModelFacilitator.processAndMergeSuggestions (merging the model's words
// with the dictionary's) and Suggest.obtainNonBatchedInputSuggestedWords (the autocorrect decision). Being a
// restatement of FUTO's code, this file is FUTO-derived: FUTO Source First License 1.1 (../../../LICENSE.md).
// It goes when FUTO's English does (stage 7 of docs/plans/android-own-keyboard.md).
#include <algorithm>
#include <cctype>
#include <climits>
#include <cmath>
#include <stdexcept>

#include "decoder.h"
#include "fake_jni.h"

namespace latinime {
int register_BinaryDictionary(JNIEnv *env);
int register_BinaryDictionaryUtils(JNIEnv *env);
int register_DicTraverseSession(JNIEnv *env);
int register_ProximityInfo(JNIEnv *env);
int register_LanguageModel(JNIEnv *env);
}  // namespace latinime

namespace harness {
namespace {

using fakejni::Arr;
using fakejni::ObjArr;
using fakejni::Str;

constexpr char PACKAGE[] = "org/futo/inputmethod";
constexpr int DECODER_MAX_RESULTS = 40;  // FUTO's MAX_RESULTS and SuggestedWords.MAX_SUGGESTIONS
constexpr float AUTOCORRECT_THRESHOLD = 0.185f;  // "modest"
constexpr float LM_AUTOCORRECT_THRESHOLD = 4.0f;  // AutocorrectThresholdSetting's default
constexpr float TRANSFORMER_WEIGHT = 3.4f;        // BinaryDictTransformerWeightSetting's default
constexpr int LM_MAX_RESULTS = 128;
constexpr int MERGED_CAPACITY = 14;
constexpr int MAX_SCORE = INT_MAX;

std::string trim(const std::string &s) {
    size_t a = 0, b = s.size();
    while (a < b && static_cast<unsigned char>(s[a]) <= ' ') a++;
    while (b > a && static_cast<unsigned char>(s[b - 1]) <= ' ') b--;
    return s.substr(a, b - a);
}
std::string lower(std::string s) {
    for (char &c : s) c = char(std::tolower(static_cast<unsigned char>(c)));
    return s;
}
size_t count(const std::string &s, char c) { return std::count(s.begin(), s.end(), c); }

// One SuggestedWordInfo; ID tells apart words that are equal but not the same object, as Kotlin's lists do.
struct Info : Word {
    int id;
};

class TodayStack : public Stack {
public:
    TodayStack(const std::string &layout, const std::string &dict, const std::string &model)
        : mProximityInfo(makeProximityInfo(PACKAGE, layout)),
          mDecoder(PACKAGE, DECODER_MAX_RESULTS, dict, mProximityInfo) {
        Str path;
        path.s = model;
        mModel = native<jlong (*)(JNIEnv *, jclass, jstring)>("openNative")(
            fakejni::env(), nullptr, fakejni::str(path));
        if (!mModel) throw std::runtime_error("today stack: the model doesn't load: " + model);
    }

    Output run(const Item &item) override {
        if (item.context != mContext) mContext = item.context, mPrevSafeguard.clear();
        mNextId = 0;

        // The dictionary's own result, as InputLogic.getSuggestedWords hands it over.
        std::vector<Word> dictResults;
        for (const Word &w : mDecoder.suggest(item)) addResult(dictResults, w, DECODER_MAX_RESULTS);
        const Suggested dict = obtain(item.typed, dictResults);

        std::vector<Info> lm = modelSuggestions(item);
        const Suggested result = lm.empty() ? dict : obtain(item.typed, merge(item, dict, lm));
        fakejni::clear();

        Output out;
        for (size_t i = item.typed.empty() ? 0 : 1; i < result.list.size(); i++) {
            const std::string &w = result.list[i].word;
            if (w != item.typed && std::find(out.strip.begin(), out.strip.end(), w) == out.strip.end())
                out.strip.push_back(w);
        }
        out.committed = result.willAutoCorrect ? result.list[1].word : item.typed;
        return out;
    }

private:
    template <class F>
    static F native(const std::string &name) {
        return reinterpret_cast<F>(fakejni::method(std::string(PACKAGE) + "/latin/xlm/LanguageModel." + name));
    }

    Info info(const Word &w) { return {w, mNextId++}; }

    // SuggestedWords as the strip gets it: the typed word first (when there is one), then the suggestions.
    struct Suggested {
        std::vector<Info> list;
        bool willAutoCorrect = false;
        int typedId = -1;
    };

    // Suggest.obtainNonBatchedInputSuggestedWords for a lowercase word of letters typed on QWERTY.
    Suggested obtain(const std::string &typed, const std::vector<Word> &results) {
        Suggested s;
        std::vector<Info> container;
        bool typedFound = false;
        for (const Word &w : results) {
            if (w.word == typed) typedFound = true;
            // removeDups("", ...): later copies of a word go; the typed word itself stays.
            if (std::none_of(container.begin(), container.end(), [&](const Info &c) { return c.word == w.word; }))
                container.push_back(info(w));
        }
        if (!typed.empty() && !results.empty()) {
            const Word &first = results.front();
            const bool whitelisted = (container.front().kind & KIND_MASK_KIND) == KIND_WHITELIST;
            const bool allowed = whitelisted || (typed.size() > 1 && !typedFound);
            const bool strongEnough =
                (first.kind & KIND_MASK_KIND) == KIND_WHITELIST ||
                ((first.kind & KIND_FLAG_APPROPRIATE_FOR_AUTO_CORRECTION) &&
                 mDecoder.normalizedScore(typed, first.word, first.score) >= AUTOCORRECT_THRESHOLD);
            s.willAutoCorrect = allowed && (first.kind & KIND_MASK_KIND) != KIND_SHORTCUT && strongEnough;
        }
        if (!typed.empty()) {
            Info t = info({typed, MAX_SCORE, KIND_TYPED});
            s.typedId = t.id;
            s.list.push_back(t);
        }
        s.list.insert(s.list.end(), container.begin(), container.end());
        return s;
    }

    // LanguageModel.kt's getContext and safeguardContext on the text before the cursor.
    std::string modelContext(const Item &item) {
        std::string context = item.context + " " + item.typed;
        context = trim(context.substr(context.rfind('\n') == std::string::npos ? 0 : context.rfind('\n') + 1));
        const std::string partial = trim(item.typed);
        if (!partial.empty() && context.size() >= partial.size() &&
            context.compare(context.size() - partial.size(), partial.size(), partial) == 0)
            context = trim(context.substr(0, context.size() - partial.size()));

        // Start where the previous context's longest matching run starts, so a trimmed sentence stays trimmed.
        int matchStart = -1, best = 0, n = 0;
        for (size_t i = 0; i <= context.size(); i++) {
            if (size_t(n) < mPrevSafeguard.size() && i < context.size() && context[i] == mPrevSafeguard[n]) {
                n++;
            } else {
                if (n >= best && n > 0) matchStart = int(i) - n, best = n;
                n = 0;
            }
        }
        if (matchStart != -1) context = context.substr(matchStart);
        auto tooLong = [](const std::string &c) { return c.size() > 70 || count(c, ' ') > 16; };
        if (tooLong(context)) {
            const size_t end = context.find_last_of(".?!");
            if (end != std::string::npos) context = trim(context.substr(end + 1));
        }
        while (tooLong(context) && context.find(',') != std::string::npos)
            context = trim(context.substr(context.find(',') + 1));
        if (tooLong(context) && context.find(' ') != std::string::npos) {
            std::vector<std::string> words;
            size_t start = 0;
            for (size_t sp; (sp = context.find(' ', start)) != std::string::npos; start = sp + 1)
                words.push_back(context.substr(start, sp - start));
            words.push_back(context.substr(start));
            std::string last;
            for (size_t i = words.size() >= 5 ? words.size() - 5 : 0; i < words.size(); i++)
                last += (last.empty() ? "" : " ") + words[i];
            context = last;
        }
        if (context.size() > 144) context.clear();
        mPrevSafeguard = context;
        return context;
    }

    // LanguageModel.getSuggestions and getSuggestionsInternal.
    std::vector<Info> modelSuggestions(const Item &item) {
        const std::string context = modelContext(item);
        std::string partial = trim(item.typed).substr(0, 40);
        Arr<jint> xs, ys;
        xs.v.assign(item.xs.begin(), item.xs.begin() + std::min<size_t>(item.xs.size(), 40));
        ys.v.assign(item.ys.begin(), item.ys.begin() + std::min<size_t>(item.ys.size(), 40));
        Str contextStr, partialStr;
        contextStr.s = context;
        partialStr.s = partial;
        ObjArr banned, outStrings;
        outStrings.v.assign(LM_MAX_RESULTS, nullptr);
        Arr<jfloat> probs;
        probs.v.assign(LM_MAX_RESULTS, 0.0f);
        native<void (*)(JNIEnv *, jclass, jlong, jlong, jstring, jstring, jint, jintArray, jintArray, jfloat,
                        jobjectArray, jobjectArray, jfloatArray)>("getSuggestionsNative")(
            fakejni::env(), nullptr, mModel, mProximityInfo, fakejni::str(contextStr), fakejni::str(partialStr), 0,
            fakejni::ints(xs), fakejni::ints(ys), LM_AUTOCORRECT_THRESHOLD, fakejni::objs(banned),
            fakejni::objs(outStrings), fakejni::floats(probs));

        auto word = [&](int i) -> const std::string * {
            return outStrings.v[i] ? fakejni::text(reinterpret_cast<jobject>(outStrings.v[i])) : nullptr;
        };
        const std::string *mode = word(LM_MAX_RESULTS - 1);
        bool canAutocorrect = mode && *mode == "autocorrect";
        for (int i = 0; i < LM_MAX_RESULTS; i++) {
            if (!word(i) || partial.empty() || lower(partial) != lower(trim(*word(i)))) continue;
            if (i == 0) break;
            if (probs.v[i] * 2.5f >= probs.v[0]) canAutocorrect = false;
        }
        const int kind = canAutocorrect && partial.size() > 1
                             ? KIND_WHITELIST | KIND_FLAG_APPROPRIATE_FOR_AUTO_CORRECTION
                             : KIND_PREDICTION;
        const bool clueless = mode && *mode == "clueless";
        const float mult = clueless ? 10.0f : 500000.0f, offset = clueless ? -100000.0f : 100000.0f;
        std::vector<Info> out;
        for (int i = 0; i < LM_MAX_RESULTS - 1; i++) {
            if (!word(i)) continue;
            const std::string w = trim(*word(i));
            out.push_back(
                info({w, int(probs.v[i] * mult + offset), kind | (w == partial ? KIND_FLAG_EXACT_MATCH : 0)}));
        }
        return out;
    }

    // LanguageModelFacilitator.processAndMergeSuggestions with one locale and no learned words.
    std::vector<Word> merge(const Item &item, const Suggested &dict, const std::vector<Info> &lm) {
        std::vector<Word> results;
        auto add = [&](const Word &w) { addResult(results, w, MERGED_CAPACITY); };
        auto maxBy = [](const std::vector<Info> &v, auto key) -> const Info * {
            const Info *best = nullptr;
            for (const Info &x : v)
                if (!best || key(x) > key(*best)) best = &x;
            return best;
        };

        std::vector<Info> reweighted;
        for (size_t i = 0; i < lm.size(); i++) {
            const long long scaled = std::min<long long>((long long)(float(lm[i].score) * TRANSFORMER_WEIGHT),
                                                         INT_MAX - (long long)lm.size());
            reweighted.push_back(info({lm[i].word, int(scaled) - int(i) + int(lm.size() - 1), lm[i].kind}));
        }
        const Info *maxWord = maxBy(reweighted, [](const Info &x) { return x.score; });

        std::vector<Info> dictList = dict.list;
        const int typedId = dict.typedId;
        const Info *maxWordDict = maxBy(dictList, [&](const Info &x) { return x.id == typedId ? INT_MIN : x.score; });
        const Info *maxNonWhitelist = maxBy(dictList, [&](const Info &x) {
            return x.id == typedId || (x.kind & KIND_MASK_KIND) == KIND_WHITELIST ? INT_MIN : x.score;
        });
        // A dictionary shortcut ("bot" -> "not") loses to the plain word when the model prefers that word.
        if (maxWordDict && maxNonWhitelist && maxNonWhitelist->id != maxWordDict->id && maxWord &&
            maxNonWhitelist->word == maxWord->word) {
            Info lowered = *maxWordDict;
            lowered.score = std::min(lowered.score, maxNonWhitelist->score - 1);
            const int nonWhitelistId = maxNonWhitelist->id;
            for (Info &x : dictList)
                if (x.id == lowered.id) x = lowered;
            maxWordDict =
                &*std::find_if(dictList.begin(), dictList.end(), [&](const Info &x) { return x.id == nonWhitelistId; });
        }

        std::vector<int> filtered;
        auto isFiltered = [&](const Info &x) {
            return std::find(filtered.begin(), filtered.end(), x.id) != filtered.end();
        };
        if (maxWord && maxWordDict && maxWordDict->word == maxWord->word) {
            const long long sum = std::max(maxWord->score, 0) + (long long)std::max(maxWordDict->score, 0);
            add({maxWord->word, int(std::min<long long>(sum, INT_MAX)),
                 KIND_WHITELIST | KIND_FLAG_APPROPRIATE_FOR_AUTO_CORRECTION});
            filtered.push_back(maxWordDict->id), filtered.push_back(maxWord->id);
        }
        if (maxWord && maxWordDict && maxWordDict->word == lower(maxWord->word)) {
            add({maxWordDict->word, std::max(maxWordDict->score, maxWord->score + 1),
                 KIND_WHITELIST | KIND_FLAG_APPROPRIATE_FOR_AUTO_CORRECTION});
            filtered.push_back(maxWordDict->id);
        }

        const bool spacePossible = maxWordDict && count(maxWordDict->word, ' ') == 1;
        bool spaceDone = false;
        for (const Info &w : reweighted) {
            if (isFiltered(w)) continue;
            if (!spaceDone && spacePossible &&
                (maxWordDict->score > w.score / 3 || w.word.find('-') != std::string::npos ||
                 double(item.typed.size()) > std::ceil(w.word.size() * 3.0 / 2.0))) {
                add({maxWordDict->word, std::max(maxWordDict->score, w.score + 1),
                     KIND_WHITELIST | KIND_FLAG_APPROPRIATE_FOR_AUTO_CORRECTION});
                spaceDone = true;
                continue;
            }
            add(w);
        }
        for (const Info &x : dictList)
            if (x.id != typedId && !isFiltered(x)) add(x);
        return results;
    }

    long long mProximityInfo;
    Decoder mDecoder;
    long long mModel = 0;
    int mNextId = 0;
    std::string mContext, mPrevSafeguard;
};

}  // namespace

std::unique_ptr<Stack> makeStack(const std::vector<std::string> &args) {
    if (args.size() != 3) throw std::runtime_error("today stack: LAYOUT DICT MODEL");
    JNIEnv *env = fakejni::env();
    if (!latinime::register_BinaryDictionary(env) || !latinime::register_BinaryDictionaryUtils(env) ||
        !latinime::register_DicTraverseSession(env) || !latinime::register_ProximityInfo(env) ||
        !latinime::register_LanguageModel(env))
        throw std::runtime_error("today stack: registering FUTO's native methods failed");
    return std::make_unique<TodayStack>(args[0], args[1], args[2]);
}

}  // namespace harness
