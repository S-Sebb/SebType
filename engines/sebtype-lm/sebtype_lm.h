// SebType's English model (tools/english-lm) on llama.cpp: next words, and how likely each of the decoder's
// candidates is the word meant by the letters typed so far.
#pragma once

#include <string>
#include <vector>

struct llama_context;
struct llama_model;
struct llama_vocab;

namespace sebtype_lm {

struct Word {
    std::string word;
    float logProb;
};

class Model {
public:
    // Loads the GGUF model at PATH; the model runs on THREADS threads.
    explicit Model(const std::string &path, int threads = 1);
    ~Model();
    Model(const Model &) = delete;
    Model &operator=(const Model &) = delete;

    // The N likeliest words to follow CONTEXT (the text before the cursor), best first, one per spelling
    // whatever its case.
    std::vector<Word> nextWords(const std::string &context, size_t n);

    // For each of WORDS, the log probability that it is the word meant by TYPED (the letters typed, any
    // case) after CONTEXT. Words are scored capitalised where a sentence starts.
    std::vector<float> score(const std::string &context, const std::string &typed,
                             const std::vector<std::string> &words);

private:
    std::vector<int> tokenize(const std::string &text, bool bos) const;
    std::vector<int> contextTokens(const std::string &context) const;
    // Brings sequence 0 to PREFIX, decoding only what the cache doesn't hold; returns the logits after it.
    const float *advance(const std::vector<int> &prefix);
    // Decodes each of FOLLOWERS after sequence 0, on a sequence of its own, with logits at every token, and
    // returns their indices for llama_get_logits_ith. The branches are gone at the next call.
    std::vector<std::vector<int>> branch(const std::vector<std::vector<int>> &followers);
    float logSoftmax(const float *logits, int token) const;
    // log P(the word ends here) and the likeliest piece continuing it, from the logits after its last piece.
    float logEnd(const float *logits, int *continuation) const;

    llama_model *mModel = nullptr;
    llama_context *mCtx = nullptr;
    const llama_vocab *mVocab = nullptr;
    int mVocabSize = 0;
    int mTypo = -1, mSep = -1;          // <T> and <S>: a correction example's start and its word's start
    std::vector<int> mLetter;            // the piece of each letter a-z and the apostrophe, as typed
    std::vector<bool> mEndsWord;         // pieces that can't continue a word: a new word, punctuation, </s>
    std::vector<bool> mWordStart;        // pieces that start a word with a letter: next-word candidates
    std::vector<std::string> mText;      // each piece's text, "▁" as a space
    std::vector<int> mCached;            // the tokens sequence 0 holds
    int mBranches = 0;                   // sequences 1..mBranches that branch() left
};

// The keyboard's strip and autocorrection from the decoder's candidates and the model's scores.
struct Candidate {
    std::string word;
    float decoderScore;  // the decoder's normalised score for the typed letters
};
struct Ranked {
    std::vector<std::string> strip;  // best first, without the typed word itself
    std::string committed;           // what a space commits: the correction, or the typed word
};
// The words rank() asks the model about: the decoder's first candidates and the typed word, last.
std::vector<std::string> rankedWords(const std::string &typed, const std::vector<Candidate> &candidates);
// CANDIDATES: the decoder's, best first, the typed word among them if the dictionary has it (TYPED_IS_WORD).
// LOG_PROBS: Model::score for rankedWords().
Ranked decide(const std::string &typed, const std::vector<Candidate> &candidates, bool typedIsWord,
              const std::vector<float> &logProbs);
inline Ranked rank(Model &model, const std::string &context, const std::string &typed,
                   const std::vector<Candidate> &candidates, bool typedIsWord) {
    return decide(typed, candidates, typedIsWord, model.score(context, typed, rankedWords(typed, candidates)));
}

}  // namespace sebtype_lm
