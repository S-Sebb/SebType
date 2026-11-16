// SebType's Chinese model (tools/chinese-lm) on llama.cpp, for the experiment of #259: how likely each of Rime's
// candidates is the text meant by the letters typed, the model's own candidates for them, and next words.
// MIT, SebType.
#pragma once

#include <string>
#include <vector>

struct llama_context;
struct llama_model;
struct llama_vocab;

namespace zh_lm {

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
    // For each of TEXTS, log P(text, then its end | CONTEXT, the letters TYPED): the model's pinyin example
    // "context <T>typed<S>text<E>".
    std::vector<float> score(const std::string &context, const std::string &typed, const std::vector<std::string> &texts);
    // The model's own candidates for TYPED: a beam search of WIDTH from <S> to <E>, best first.
    std::vector<Text> generate(const std::string &context, const std::string &typed, int width, int maxChars);
    // The N likeliest words (1 to 4 Han characters, ending where the model's <B> says a word ends) after CONTEXT.
    std::vector<Text> nextWords(const std::string &context, size_t n);

private:
    std::vector<int> tokenize(const std::string &text) const;
    std::vector<int> contextTokens(const std::string &context) const;
    std::vector<int> examplePrefix(const std::string &context, const std::string &typed) const;
    const float *advance(const std::vector<int> &prefix);
    // Decodes FOLLOWERS after sequence 0 as a tree, each on a sequence of its own, and returns the batch index
    // of each of their tokens' logits.
    std::vector<std::vector<int>> branch(const std::vector<std::vector<int>> &followers);
    // log softmax over every token but <B>.
    float logNorm(const float *logits) const;
    float logEnd(const float *logits) const;  // log sigmoid of <B>'s logit: a word ends at this token

    llama_model *mModel = nullptr;
    llama_context *mCtx = nullptr;
    const llama_vocab *mVocab = nullptr;
    int mVocabSize = 0;
    int mT = -1, mS = -1, mE = -1, mB = -1, mBos = -1;
    std::vector<int> mLetter;  // a-z
    std::vector<bool> mHan;    // pieces that are one Han character
    std::vector<std::string> mText;
    std::vector<int> mCached;
    int mBranches = 0;
};

}  // namespace zh_lm
