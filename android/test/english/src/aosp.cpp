// The pristine AOSP stack: AOSP LatinIME's decoder (Apache-2.0, fetched by bench.sh) with no language model.
// The strip and autocorrection follow AOSP's Suggest.getSuggestedWordsForNonBatchInput at the "modest"
// threshold, with one main dictionary and nothing learned.
#include <algorithm>
#include <stdexcept>

#include "decoder.h"
#include "fake_jni.h"

namespace latinime {
int register_BinaryDictionary(JNIEnv *env);
int register_BinaryDictionaryUtils(JNIEnv *env);
int register_DicTraverseSession(JNIEnv *env);
int register_ProximityInfo(JNIEnv *env);
}  // namespace latinime

namespace harness {
namespace {

constexpr char PACKAGE[] = "com/android/inputmethod";
constexpr int MAX_RESULTS = 18;  // AOSP's DicTraverseSession.MAX_RESULTS and SuggestedWords.MAX_SUGGESTIONS
constexpr float AUTOCORRECT_THRESHOLD = 0.185f;

class AospStack : public Stack {
public:
    AospStack(const std::string &layout, const std::string &dict)
        : mDecoder(PACKAGE, MAX_RESULTS, dict, makeProximityInfo(PACKAGE, layout)) {}

    Output run(const Item &item) override {
        std::vector<Word> results;
        for (const Word &w : mDecoder.suggest(item)) addResult(results, w, MAX_RESULTS);

        // The typed word leaves the list; whether it was there decides if it may be corrected at all.
        bool typedFound = false;
        std::vector<std::string> strip;
        for (const Word &w : results) {
            if (w.word == item.typed) typedFound = true;
            else if (std::find(strip.begin(), strip.end(), w.word) == strip.end()) strip.push_back(w.word);
        }
        Output out{strip, item.typed};
        if (item.typed.empty() || results.empty() || strip.empty()) return out;

        const Word &first = results.front();
        const bool whitelisted = (first.kind & KIND_MASK_KIND) == KIND_WHITELIST;
        const bool allowed = whitelisted || (item.typed.size() > 1 && !typedFound);
        const bool strongEnough =
            whitelisted || ((first.kind & KIND_FLAG_APPROPRIATE_FOR_AUTO_CORRECTION) &&
                            mDecoder.normalizedScore(item.typed, first.word, first.score) >= AUTOCORRECT_THRESHOLD);
        if (allowed && (first.kind & KIND_MASK_KIND) != KIND_SHORTCUT && strongEnough) out.committed = strip.front();
        return out;
    }

private:
    Decoder mDecoder;
};

}  // namespace

std::unique_ptr<Stack> makeStack(const std::vector<std::string> &args) {
    if (args.size() != 2) throw std::runtime_error("aosp stack: LAYOUT DICT");
    JNIEnv *env = fakejni::env();
    if (!latinime::register_BinaryDictionary(env) || !latinime::register_BinaryDictionaryUtils(env) ||
        !latinime::register_DicTraverseSession(env) || !latinime::register_ProximityInfo(env))
        throw std::runtime_error("aosp stack: registering the decoder's native methods failed");
    return std::make_unique<AospStack>(args[0], args[1]);
}

}  // namespace harness
