// AOSP's decoder with SebType's own English model (engines/sebtype-lm, stage 7 of the plan): the decoder
// finds the candidates for the typed letters, the model ranks them, decides the autocorrection and gives the
// next words.
//
// With SEBTYPE_LM_DUMP=FILE, every call also appends decide()'s inputs, for tools/english-lm/tune.py to replay
// it: context, typed, whether the typed word is a dictionary word, the typed word's ending term, then per scored
// word its text, the decoder's normalised score, the model's log probability, the same read after the typed
// letters' hint (AS_TYPED) and its pieces' alone, which tools/english-lm/parity.py checks the export by (#609).
#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <stdexcept>

#include "decoder.h"
#include "fake_jni.h"
#include "sebtype_lm.h"

namespace latinime {
int register_BinaryDictionary(JNIEnv *env);
int register_BinaryDictionaryUtils(JNIEnv *env);
int register_DicTraverseSession(JNIEnv *env);
int register_ProximityInfo(JNIEnv *env);
}  // namespace latinime

namespace harness {
namespace {

constexpr char PACKAGE[] = "com/android/inputmethod";
constexpr int MAX_RESULTS = 18;

class SebTypeStack : public Stack {
public:
    SebTypeStack(const std::string &layout, const std::string &dict, const std::string &model)
        : mDecoder(PACKAGE, MAX_RESULTS, dict, makeProximityInfo(PACKAGE, layout)), mModel(model, 1) {
        if (const char *dump = std::getenv("SEBTYPE_LM_DUMP")) mDump.open(dump, std::ios::app);
    }

    Output run(const Item &item) override {
        if (item.typed.empty()) {
            Output out;
            for (const auto &w : mModel.nextWords(item.context, 3)) out.strip.push_back(w.word);
            return out;
        }
        std::vector<Word> results;
        for (const Word &w : mDecoder.suggest(item)) addResult(results, w, MAX_RESULTS);
        std::vector<sebtype_lm::Candidate> candidates;
        bool typedIsWord = false;
        for (const Word &w : results) {
            typedIsWord |= w.word == item.typed;
            candidates.push_back({w.word, mDecoder.normalizedScore(item.typed, w.word, w.score)});
        }
        const auto words = sebtype_lm::rankedWords(item.typed, candidates);
        std::vector<float> asTyped, pieces;
        float typedEnd = 0;
        const auto logProbs =
            mModel.score(item.context, item.typed, words, typedIsWord, &asTyped, false, &typedEnd, &pieces);
        if (mDump.is_open()) {
            mDump << item.context << '\t' << item.typed << '\t' << typedIsWord << '\t' << typedEnd;
            for (size_t i = 0; i < words.size(); i++) {
                float decoder = 0;
                for (const auto &c : candidates)
                    if (c.word == words[i]) decoder = std::max(decoder, c.decoderScore);
                mDump << '\t' << words[i] << '\t' << decoder << '\t' << logProbs[i] << '\t' << asTyped[i] << '\t'
                      << pieces[i];
            }
            mDump << '\n';
        }
        const auto ranked = sebtype_lm::decide(item.typed, candidates, typedIsWord, logProbs, false, asTyped, typedEnd);
        return {ranked.strip, ranked.committed};
    }

private:
    Decoder mDecoder;
    sebtype_lm::Model mModel;
    std::ofstream mDump;
};

}  // namespace

std::unique_ptr<Stack> makeStack(const std::vector<std::string> &args) {
    if (args.size() != 3) throw std::runtime_error("sebtype stack: LAYOUT DICT MODEL");
    JNIEnv *env = fakejni::env();
    if (!latinime::register_BinaryDictionary(env) || !latinime::register_BinaryDictionaryUtils(env) ||
        !latinime::register_DicTraverseSession(env) || !latinime::register_ProximityInfo(env))
        throw std::runtime_error("sebtype stack: registering the decoder's native methods failed");
    return std::make_unique<SebTypeStack>(args[0], args[1], args[2]);
}

}  // namespace harness
