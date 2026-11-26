// SebType's English model (tools/english-lm) on llama.cpp: next words, and how likely each of the decoder's
// candidates is the word meant by the letters typed so far.
#pragma once

#include <map>
#include <string>
#include <utility>
#include <vector>

struct llama_context;
struct llama_model;
struct llama_vocab;

namespace sebtype_lm {

struct Word {
    std::string word;
    float logProb;
};

// What Model::score() read each word's pieces from, for tools/english-lm/parity.py to read the same tokens
// with the checkpoint (#609): the prompt up to the hint's <S>, and per word its pieces and their log
// probabilities summed, without its ending or a share.
struct PieceScores {
    std::vector<int> prompt;
    std::vector<std::vector<int>> pieces;
    std::vector<float> logProbs;
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
    // case) after CONTEXT. Words are scored as they would show: in capitals if TYPED is, else capitalised where
    // a sentence starts or TYPED is. TYPED_IS_WORD: TYPED is a dictionary word, which a contraction of its
    // letters may not outscore by more than the context allows.
    // AS_TYPED, if given and TYPED is a word: each word's log probability read after TYPED's letters as its
    // hint, as all but a contraction of them are read, before that contraction and TYPED share their odds.
    // TYPED_KEPT: TYPED stays whatever it scores (a learned word), so where it ends isn't read unless a
    // contraction shares with it. TYPED_END, if given: the part of TYPED's score that is its ending there.
    // PIECE_SCORES, if given: the tokens each word was read from and their raw scores.
    std::vector<float> score(const std::string &context, const std::string &typed,
                             const std::vector<std::string> &words, bool typedIsWord,
                             std::vector<float> *asTyped = nullptr, bool typedKept = false,
                             float *typedEnd = nullptr, PieceScores *pieceScores = nullptr);

    // The part of CONTEXT both read: its last line, the last 150 to 300 characters of it from a word's start,
    // starting where the last call's window started while that leaves 150 to 300 characters (#359).
    std::string window(const std::string &context) const;

private:
    std::vector<int> tokenize(const std::string &text, bool bos) const;
    std::vector<int> contextTokens(const std::string &context);
    // Brings sequence 0 to PREFIX, decoding only what the cache doesn't hold; returns the logits after it.
    const float *advance(const std::vector<int> &prefix);
    // Decodes each of FOLLOWERS on a sequence of its own, after sequence 0's tokens before its place in FROM
    // (empty: all of them), with logits only at the tokens READ marks, and returns their indices for
    // branchLogits(). The branches are gone at the next call.
    std::vector<std::vector<int>> branch(const std::vector<std::vector<int>> &followers,
                                         const std::vector<size_t> &from,
                                         const std::vector<std::vector<bool>> &read);
    // The logits after the token at index AT of branch()'s last call.
    const float *branchLogits(int at);
    // What is read from a row of logits, in one pass over the vocabulary, which costs 0.5 ms on a phone's
    // little cores (#406): its normaliser, log P(the word before ends here), and the likeliest piece continuing
    // that word (-1 if none).
    struct Row {
        float top;
        float log;
        float end;
        int next;
    };
    Row row(const float *logits) const;
    static float logSoftmax(const float *logits, int token, const Row &r);
    // Drops the sequences branch() left.
    void dropBranches();

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
    std::string mWindow;                 // the last window read
    int mBranches = 0;                   // sequences 1..mBranches that branch() left
    // The logits branch() read when its tokens took more than one batch, by index (empty: they are llama's).
    std::map<int, std::vector<float>> mSplitLogits;
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
// LOG_PROBS and AS_TYPED: Model::score for rankedWords(). TYPED_IS_LEARNED: the typed word is one the user's
// learned or personal words have and the dictionary doesn't, which a space keeps as typed. TYPED_END: Model::
// score's.
Ranked decide(const std::string &typed, const std::vector<Candidate> &candidates, bool typedIsWord,
              const std::vector<float> &logProbs, bool typedIsLearned = false,
              const std::vector<float> &asTyped = {}, float typedEnd = 0);
inline Ranked rank(Model &model, const std::string &context, const std::string &typed,
                   const std::vector<Candidate> &candidates, bool typedIsWord, bool typedIsLearned = false) {
    std::vector<float> asTyped;
    float typedEnd = 0;
    const auto logProbs = model.score(context, typed, rankedWords(typed, candidates), typedIsWord, &asTyped,
                                      typedIsLearned, &typedEnd);
    return decide(typed, candidates, typedIsWord, logProbs, typedIsLearned, asTyped, typedEnd);
}

}  // namespace sebtype_lm
