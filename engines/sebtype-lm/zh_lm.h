// SebType's Chinese model (tools/chinese-lm) on llama.cpp (#259, #264): how likely each of Rime's candidates is
// the text meant by the letters typed, the model's own candidates for them, and next words. Not thread-safe:
// one thread at a time. MIT, SebType.
#pragma once

#include <functional>
#include <map>
#include <string>
#include <utility>
#include <vector>

struct ggml_threadpool;
struct llama_context;
struct llama_model;
struct llama_vocab;

namespace zh_lm {

// The letters the model reads, at most: with the context, a candidate and its end, within the 256 positions it
// was trained on. The rest are left out.
constexpr size_t MAX_LETTERS = 64;

// Where a key's time goes (main.cpp's profile=1): microseconds per step since the last reset, and counts.
struct Profile {
    enum Step { Prefix, Advance, BeamNorm, BeamDecode, BeamCache, BranchCache, BranchDecode, ScoreNorm, Steps };
    static constexpr const char *names[Steps] = {"prefix", "advance", "beam_norm", "beam_decode", "beam_cache",
                                                 "branch_cache", "branch_decode", "score_norm"};
    double us[Steps] = {};
    int decodes = 0, tokens = 0;
};

struct Text {
    std::string text;
    float logProb;
};

class Model {
public:
    explicit Model(const std::string &path, int threads = 1);
    ~Model();
    Model(const Model &) = delete;
    Model &operator=(const Model &) = delete;

    // Reads CONTEXT ahead, as the keyboard would when the text before the cursor changes, so the calls below
    // decode only what follows it.
    void prime(const std::string &context);
    // For each of TEXTS, log P(text, then its end, and a word ending with it | CONTEXT, the letters TYPED): the
    // model's pinyin example "context <T>typed<S>text<E>", with <B>'s chance that a word ends at its last
    // character, so that a text which stops inside a word (剪个深) scores low (#502).
    std::vector<float> score(const std::string &context, const std::string &typed, const std::vector<std::string> &texts);
    // The model's own candidates for TYPED: a beam search of WIDTH from <S>, where every beam also ends at <E>,
    // best first, each with its log probability as score() would give it. After score() with the same CONTEXT
    // and TYPED, it decodes only the steps off the texts score() decoded.
    std::vector<Text> generate(const std::string &context, const std::string &typed, int width, int maxChars);
    // For each of TEXTS, log P(text | CONTEXT) as plain text, with no letters: score() alone overrates a text
    // whose first character fits the letters and the context but whose rest doesn't (剪个深 for jiangeshen),
    // as the letters leave the model no choice once it is there (#502). Call it after generate(), which
    // reuses score()'s tree.
    std::vector<float> plain(const std::string &context, const std::vector<std::string> &texts);
    // The N likeliest words (1 to 4 Han characters, ending where the model's <B> says a word ends) after CONTEXT.
    std::vector<Text> nextWords(const std::string &context, size_t n);

    Profile profile;
    // Asked between generate()'s steps: true ends it early, with no candidates (the letters changed since).
    std::function<bool()> stale;

private:
    std::vector<int> tokenize(const std::string &text) const;
    std::vector<int> contextTokens(const std::string &context) const;
    std::vector<int> examplePrefix(const std::string &context, const std::string &typed) const;
    const float *advance(const std::vector<int> &prefix);
    void clearBranches();
    void release();  // frees the model, its context and its threads
    // Decodes the example PREFIX after what the cache holds of it, and FOLLOWERS after it as a tree, each on a
    // sequence of its own, in one batch, into mNodes.
    void decodeExample(const std::vector<int> &prefix, const std::vector<std::vector<int>> &followers);
    // Each of PATHS' log probability in the tree decodeExample() left, with <B> at an <E>; -inf for one left out.
    std::vector<float> pathScores(const std::vector<std::vector<int>> &paths);
    // log softmax over every token but <B>.
    float logNorm(const float *logits) const;
    float logEnd(const float *logits) const;  // log sigmoid of <B>'s logit: a word ends at this token

    llama_model *mModel = nullptr;
    llama_context *mCtx = nullptr;
    ggml_threadpool *mPool = nullptr;
    void (*mFreePool)(ggml_threadpool *) = nullptr;
    const llama_vocab *mVocab = nullptr;
    int mVocabSize = 0;
    int mT = -1, mS = -1, mE = -1, mB = -1, mBos = -1;
    std::vector<int> mLetter;  // a-z
    std::vector<int> mHan;  // pieces that are one Han character
    std::vector<std::string> mText;
    std::map<std::string, int> mPiece;  // by its text in the vocabulary
    std::vector<int> mCached;
    int mBranches = 0;
    // A text decoded after the example mExample, by its tokens after <S> ({} is <S> itself).
    struct Node {
        int seq;  // a sequence whose cache holds the node's tokens, and maybe more after them
        float norm;  // logNorm(logits)
        std::vector<float> logits;  // for the token after it
    };
    std::vector<int> mExample;
    std::map<std::vector<int>, Node> mNodes;
    std::vector<std::vector<int>> mGuesses;  // generate()'s last candidates, which score() decodes too
    std::pair<size_t, std::vector<Text>> mEmptyWords;  // nextWords() for an empty field, and its N
};

}  // namespace zh_lm
