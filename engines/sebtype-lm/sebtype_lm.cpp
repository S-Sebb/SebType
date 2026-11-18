// SebType's English model on llama.cpp's public API (llama.h). The model's text format is tools/english-lm's
// (pack.py): <s> text, and a correction example "<T>typed letters<S>word" in front of a word.
#include "sebtype_lm.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <map>
#include <mutex>
#include <stdexcept>

#include "llama.h"

namespace sebtype_lm {
namespace {

constexpr size_t CONTEXT_CHARS = 300;  // the text before the cursor the model reads, at most
constexpr size_t CONTEXT_STEP = 150;   // how much the window grows before its start moves (#359)
constexpr int MAX_BRANCHES = 32;
constexpr int NEXT_WORD_PIECES = 5;  // first pieces nextWords() follows to the end of their word
constexpr size_t SCORED_CANDIDATES = 6;
// decide()'s weights, tuned on tools/english-lm's own dev sets (tune.py), never on the harness's test sets.
// MARGIN_NON_WORD: 10 changes no more dev words than 12 did; the harness's clean words changed 0.2 -> 0.3 %, accepted
// for 12 points more misspellings fixed (#291).
constexpr float DECODER_WEIGHT = 1.5f;  // of the log of the decoder's normalised score
constexpr float MIN_DECODER_SCORE = 1e-3f;
constexpr float MARGIN_WORD = 4.0f;     // how much likelier a correction must be than a typed dictionary word
constexpr float MARGIN_NON_WORD = 10.0f;  // ... than typed letters that aren't a word
const std::string SPACE = "\xe2\x96\x81";  // "▁"

bool sentenceStart(const std::string &context) {
    const auto end = context.find_last_not_of(" \n");
    return end == std::string::npos || std::string(".!?\n").find(context[end]) != std::string::npos;
}

std::string lower(std::string s) {
    for (char &c : s) c = std::tolower(static_cast<unsigned char>(c));
    return s;
}

}  // namespace

Model::Model(const std::string &path, int threads) {
    static std::once_flag backend;
    std::call_once(backend, [] {
        llama_log_set([](ggml_log_level level, const char *text, void *) {
            if (level >= GGML_LOG_LEVEL_ERROR) fputs(text, stderr);
        }, nullptr);
        llama_backend_init();
    });
    auto mp = llama_model_default_params();
    mp.n_gpu_layers = 0;
    mModel = llama_model_load_from_file(path.c_str(), mp);
    if (!mModel) throw std::runtime_error("sebtype-lm: can't load " + path);
    auto cp = llama_context_default_params();
    cp.n_ctx = 1024;
    cp.n_batch = cp.n_ubatch = 256;
    cp.n_seq_max = MAX_BRANCHES + 1;
    cp.n_threads = cp.n_threads_batch = threads;
    cp.kv_unified = true;  // the branches share sequence 0's cells
    cp.no_perf = true;
    mCtx = llama_init_from_model(mModel, cp);
    if (!mCtx) throw std::runtime_error("sebtype-lm: can't make a context for " + path);
    mVocab = llama_model_get_vocab(mModel);
    mVocabSize = llama_vocab_n_tokens(mVocab);

    std::map<std::string, int> single;
    mEndsWord.resize(mVocabSize);
    mWordStart.resize(mVocabSize);
    mText.resize(mVocabSize);
    for (int t = 0; t < mVocabSize; t++) {
        std::string text = llama_vocab_get_text(mVocab, t);
        if (text == "<T>") mTypo = t;
        if (text == "<S>") mSep = t;
        const bool space = text.rfind(SPACE, 0) == 0;
        std::string word = space ? text.substr(SPACE.size()) : text;
        const bool letter = !word.empty() && std::isalpha(static_cast<unsigned char>(word[0]));
        const bool apostrophe = !word.empty() && word[0] == '\'';
        const bool control = llama_vocab_is_control(mVocab, t) || llama_vocab_is_eog(mVocab, t);
        // A piece continues the word before it only if it starts with a letter or an apostrophe, no space.
        mEndsWord[t] = space || control || !(letter || apostrophe);
        mWordStart[t] = space && letter && !control;
        mText[t] = (space ? " " : "") + word;
        if (!space && !control) single.emplace(word, t);
    }
    for (char c : std::string("abcdefghijklmnopqrstuvwxyz'")) {
        auto it = single.find(std::string(1, c));
        if (it == single.end()) throw std::runtime_error("sebtype-lm: no piece for a typed letter");
        mLetter.push_back(it->second);
    }
    if (mTypo < 0 || mSep < 0) throw std::runtime_error("sebtype-lm: not a SebType model (no <T> or <S>)");
}

Model::~Model() {
    if (mCtx) llama_free(mCtx);
    if (mModel) llama_model_free(mModel);
}

std::vector<int> Model::tokenize(const std::string &text, bool bos) const {
    std::vector<int> out(text.size() + 2);
    int n = llama_tokenize(mVocab, text.data(), text.size(), out.data(), out.size(), bos, false);
    if (n < 0) {
        out.resize(-n);
        n = llama_tokenize(mVocab, text.data(), text.size(), out.data(), out.size(), bos, false);
    }
    out.resize(std::max(n, 0));
    return out;
}

std::string Model::window(const std::string &context) const {
    // The last line, without the spaces after it, and past CONTEXT_CHARS from a word's start. The start
    // stays where the last window started while it leaves CONTEXT_CHARS - CONTEXT_STEP to CONTEXT_CHARS, so
    // the cache holds it and only new words are decoded; a start that moved with each word decoded the whole
    // window each time, 8x a short field's cost on the phone (#359). It is found by the last window's text,
    // not by its offset: the engine's context is the field's last 1,000 characters, cut again whenever it
    // reads the field. engines/sebtype-lm/bench/bench.sh chose 300 and 150: as good as a fixed 300.
    const auto newline = context.rfind('\n');
    std::string line = context.substr(newline == std::string::npos ? 0 : newline + 1);
    line.erase(line.find_last_not_of(' ') + 1);
    if (line.size() <= CONTEXT_CHARS) return line;
    if (!mWindow.empty()) {
        const auto at = line.find(mWindow, line.size() - CONTEXT_CHARS);
        if (at != std::string::npos && line.size() - at >= CONTEXT_CHARS - CONTEXT_STEP && line[at - 1] == ' ')
            return line.substr(at);
    }
    const auto space = line.find(' ', line.size() - (CONTEXT_CHARS - CONTEXT_STEP));
    return space == std::string::npos ? "" : line.substr(space + 1);
}

std::vector<int> Model::contextTokens(const std::string &context) {
    mWindow = window(context);
    return tokenize(mWindow, true);
}

const float *Model::advance(const std::vector<int> &prefix) {
    llama_memory_t mem = llama_get_memory(mCtx);
    for (int s = 1; s <= mBranches; s++) llama_memory_seq_rm(mem, s, -1, -1);
    mBranches = 0;
    size_t keep = 0;
    while (keep < mCached.size() && keep < prefix.size() && mCached[keep] == prefix[keep]) keep++;
    keep = std::min(keep, prefix.size() - 1);  // the last token is decoded again for its logits
    llama_memory_seq_rm(mem, 0, keep, -1);
    const int nBatch = llama_n_batch(mCtx);
    llama_batch batch = llama_batch_init(nBatch, 0, 1);
    for (size_t start = keep; start < prefix.size(); start += nBatch) {
        batch.n_tokens = 0;
        for (size_t i = start; i < prefix.size() && i < start + nBatch; i++) {
            const int k = batch.n_tokens++;
            batch.token[k] = prefix[i];
            batch.pos[k] = i;
            batch.n_seq_id[k] = 1;
            batch.seq_id[k][0] = 0;
            batch.logits[k] = i + 1 == prefix.size();
        }
        if (llama_decode(mCtx, batch) != 0) {
            llama_batch_free(batch);
            mCached.clear();
            llama_memory_seq_rm(mem, 0, -1, -1);
            throw std::runtime_error("sebtype-lm: decoding failed");
        }
    }
    llama_batch_free(batch);
    mCached = prefix;
    return llama_get_logits_ith(mCtx, -1);
}

std::vector<std::vector<int>> Model::branch(const std::vector<std::vector<int>> &followers) {
    // A tree: followers that start alike share those tokens, decoded once on all their sequences.
    llama_memory_t mem = llama_get_memory(mCtx);
    std::map<std::vector<int>, int> node;  // a follower's first tokens -> their last token's batch index
    std::vector<std::vector<int>> index(followers.size()), seqs;
    std::vector<int> tokens;
    std::vector<size_t> depth;
    for (size_t i = 0; i < followers.size(); i++) {
        if (followers[i].empty()) continue;
        const int seq = ++mBranches;
        llama_memory_seq_cp(mem, 0, seq, -1, -1);
        std::vector<int> path;
        for (int t : followers[i]) {
            path.push_back(t);
            auto [it, added] = node.emplace(path, tokens.size());
            if (added) tokens.push_back(t), depth.push_back(path.size() - 1), seqs.emplace_back();
            seqs[it->second].push_back(seq);
            index[i].push_back(it->second);
        }
    }
    if (tokens.empty()) return index;
    llama_batch batch = llama_batch_init(tokens.size(), 0, mBranches);
    for (size_t k = 0; k < tokens.size(); k++) {
        batch.token[k] = tokens[k];
        batch.pos[k] = mCached.size() + depth[k];
        batch.n_seq_id[k] = seqs[k].size();
        for (size_t j = 0; j < seqs[k].size(); j++) batch.seq_id[k][j] = seqs[k][j];
        batch.logits[k] = true;
    }
    batch.n_tokens = tokens.size();
    const int status = llama_decode(mCtx, batch);
    llama_batch_free(batch);
    if (status != 0) throw std::runtime_error("sebtype-lm: decoding failed");
    return index;
}

float Model::logSoftmax(const float *logits, int token) const {
    const float top = *std::max_element(logits, logits + mVocabSize);
    double sum = 0;
    for (int t = 0; t < mVocabSize; t++) sum += std::exp(logits[t] - top);
    return logits[token] - top - std::log(sum);
}

float Model::logEnd(const float *logits, int *continuation) const {
    const float top = *std::max_element(logits, logits + mVocabSize);
    double sum = 0, end = 0;
    int best = -1;
    for (int t = 0; t < mVocabSize; t++) {
        const double p = std::exp(logits[t] - top);
        sum += p;
        if (mEndsWord[t]) end += p;
        else if (best < 0 || logits[t] > logits[best]) best = t;
    }
    if (continuation) *continuation = best;
    return std::log(end / sum);
}

std::vector<Word> Model::nextWords(const std::string &context, size_t n) {
    const float *logits = advance(contextTokens(context));
    std::vector<int> first;
    for (int t = 0; t < mVocabSize; t++)
        if (mWordStart[t]) first.push_back(t);
    const size_t k = std::min<size_t>(NEXT_WORD_PIECES, first.size());
    std::partial_sort(first.begin(), first.begin() + k, first.end(),
                      [&](int a, int b) { return logits[a] > logits[b]; });
    first.resize(k);
    std::vector<float> lp;
    for (int t : first) lp.push_back(logSoftmax(logits, t));

    // Each first piece either ends its word or goes on with its likeliest continuation.
    std::vector<std::vector<int>> followers;
    for (int t : first) followers.push_back({t});
    const auto index = branch(followers);
    std::vector<Word> words;
    for (size_t i = 0; i < first.size(); i++) {
        const float *after = llama_get_logits_ith(mCtx, index[i][0]);
        int next = -1;
        const float end = logEnd(after, &next);
        const float more = next >= 0 ? logSoftmax(after, next) : -INFINITY;
        std::string word = mText[first[i]].substr(1);
        if (more > end) word += mText[next];
        words.push_back({word, lp[i] + std::max(end, more)});
    }
    std::stable_sort(words.begin(), words.end(), [](const Word &a, const Word &b) { return a.logProb > b.logProb; });
    std::vector<Word> out;
    for (const Word &w : words) {
        const bool seen = std::any_of(out.begin(), out.end(), [&](const Word &o) { return lower(o.word) == lower(w.word); });
        if (!seen && out.size() < n) out.push_back(w);
    }
    return out;
}

std::vector<float> Model::score(const std::string &context, const std::string &typed,
                                const std::vector<std::string> &words) {
    std::vector<int> prefix = contextTokens(context);
    prefix.push_back(mTypo);
    for (char c : lower(typed)) {
        const auto i = std::string("abcdefghijklmnopqrstuvwxyz'").find(c);
        if (i != std::string::npos) prefix.push_back(mLetter[i]);
    }
    prefix.push_back(mSep);
    const float *logits = advance(prefix);

    const bool capital = sentenceStart(context);
    std::vector<std::vector<int>> pieces;
    std::vector<float> out;
    for (std::string w : words) {
        if (capital && !w.empty()) w[0] = std::toupper(static_cast<unsigned char>(w[0]));
        pieces.push_back(tokenize(w, false));
        out.push_back(pieces.back().empty() ? -INFINITY : logSoftmax(logits, pieces.back()[0]));
    }
    // A word of several pieces: the probability of each further piece after those before it.
    std::vector<std::vector<int>> followers;
    for (const auto &p : pieces) followers.emplace_back(p.begin(), p.end() - (p.empty() ? 0 : 1));
    const auto index = branch(followers);
    for (size_t i = 0; i < pieces.size(); i++)
        for (size_t j = 0; j < index[i].size(); j++)
            out[i] += logSoftmax(llama_get_logits_ith(mCtx, index[i][j]), pieces[i][j + 1]);
    return out;
}

std::vector<std::string> rankedWords(const std::string &typed, const std::vector<Candidate> &candidates) {
    std::vector<std::string> words;
    for (const Candidate &c : candidates)
        if (c.word != typed && words.size() < SCORED_CANDIDATES &&
            std::find(words.begin(), words.end(), c.word) == words.end())
            words.push_back(c.word);
    words.push_back(typed);
    return words;
}

Ranked decide(const std::string &typed, const std::vector<Candidate> &candidates, bool typedIsWord,
              const std::vector<float> &logProbs) {
    const auto words = rankedWords(typed, candidates);
    std::vector<float> score(words.size());
    for (size_t i = 0; i < words.size(); i++) {
        float decoder = 0;
        for (const Candidate &c : candidates)
            if (c.word == words[i]) decoder = std::max(decoder, c.decoderScore);
        score[i] = logProbs[i] + DECODER_WEIGHT * std::log(std::max(decoder, MIN_DECODER_SCORE));
    }
    std::vector<size_t> order(words.size() - 1);  // the typed word is last
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return score[a] > score[b]; });
    Ranked out{{}, typed};
    for (size_t i : order) out.strip.push_back(words[i]);
    const float margin = typedIsWord ? MARGIN_WORD : MARGIN_NON_WORD;
    if (!order.empty() && typed.size() > 1 && score[order[0]] - score.back() > margin) out.committed = words[order[0]];
    return out;
}

}  // namespace sebtype_lm
