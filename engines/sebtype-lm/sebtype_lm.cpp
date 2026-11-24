// SebType's English model on llama.cpp's public API (llama.h). The model's text format is tools/english-lm's
// (pack.py): <s> text, and a correction example "<T>typed letters<S>word" in front of a word.
#include "sebtype_lm.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <functional>
#include <map>
#include <mutex>
#include <set>
#include <stdexcept>

#include "llama.h"

namespace sebtype_lm {
namespace {

constexpr size_t CONTEXT_CHARS = 300;  // the text before the cursor the model reads, at most
constexpr size_t CONTEXT_STEP = 150;   // how much the window grows before its start moves (#359)
constexpr int MAX_BRANCHES = 32;
constexpr int NEXT_WORD_PIECES = 5;  // first pieces nextWords() follows to the end of their word
constexpr int NEXT_WORD_MAX_PIECES = 4;  // a next word's pieces, at most: o'clock is 4
constexpr size_t SCORED_CANDIDATES = 6;
// decide()'s weights, tuned on tools/english-lm's own dev sets (tune.py), never on the harness's test sets.
// MARGIN_NON_WORD: 10 changes no more dev words than 12 did; the harness's clean words changed 0.2 -> 0.3 %, accepted
// for 12 points more misspellings fixed (#291).
constexpr float DECODER_WEIGHT = 1.5f;  // of the log of the decoder's normalised score
constexpr float MIN_DECODER_SCORE = 1e-3f;
// The dictionary's shortcuts (ill -> I'll, cant -> can't) score about 1,600 where a word typed exactly scores
// under 2: uncapped, they outweighed whatever the text before says ("I feel ill", "Show your id"). Chosen on
// #561's contraction and homograph probe: 10 keeps every homograph in its context and the shortcuts elsewhere.
constexpr float MAX_DECODER_SCORE = 10.0f;
constexpr float MARGIN_WORD = 4.0f;     // how much likelier a correction must be than a typed dictionary word
constexpr float MARGIN_NON_WORD = 10.0f;  // ... than typed letters that aren't a word
const std::string SPACE = "\xe2\x96\x81";  // "▁"
const std::set<std::string> CONTRACTION_ENDS = {"t", "s", "d", "m", "ll", "re", "ve"};

bool sentenceStart(const std::string &context) {
    const auto end = context.find_last_not_of(" \n");
    return end == std::string::npos || std::string(".!?\n").find(context[end]) != std::string::npos;
}

std::string lower(std::string s) {
    for (char &c : s) c = std::tolower(static_cast<unsigned char>(c));
    return s;
}

// The model's text is ASCII: tools/english-lm/corpus.py folds its sources to it (FOLD, then accents dropped
// by NFKD) and leaves out the lines that still aren't. This is that folding for the code points up to U+017F
// and FOLD's punctuation, made from corpus.py; any other code point is left out (#561).
const std::pair<char32_t, const char *> FOLDED[] = {
    {0xa0, " "}, {0xa8, " "}, {0xaa, "a"}, {0xaf, " "}, {0xb2, "2"}, {0xb3, "3"}, {0xb4, " "}, {0xb8, " "},
    {0xb9, "1"}, {0xba, "o"}, {0xc0, "A"}, {0xc1, "A"}, {0xc2, "A"}, {0xc3, "A"}, {0xc4, "A"}, {0xc5, "A"},
    {0xc6, "AE"}, {0xc7, "C"}, {0xc8, "E"}, {0xc9, "E"}, {0xca, "E"}, {0xcb, "E"}, {0xcc, "I"}, {0xcd, "I"},
    {0xce, "I"}, {0xcf, "I"}, {0xd1, "N"}, {0xd2, "O"}, {0xd3, "O"}, {0xd4, "O"}, {0xd5, "O"}, {0xd6, "O"},
    {0xd8, "O"}, {0xd9, "U"}, {0xda, "U"}, {0xdb, "U"}, {0xdc, "U"}, {0xdd, "Y"}, {0xdf, "ss"}, {0xe0, "a"},
    {0xe1, "a"}, {0xe2, "a"}, {0xe3, "a"}, {0xe4, "a"}, {0xe5, "a"}, {0xe6, "ae"}, {0xe7, "c"}, {0xe8, "e"},
    {0xe9, "e"}, {0xea, "e"}, {0xeb, "e"}, {0xec, "i"}, {0xed, "i"}, {0xee, "i"}, {0xef, "i"}, {0xf1, "n"},
    {0xf2, "o"}, {0xf3, "o"}, {0xf4, "o"}, {0xf5, "o"}, {0xf6, "o"}, {0xf8, "o"}, {0xf9, "u"}, {0xfa, "u"},
    {0xfb, "u"}, {0xfc, "u"}, {0xfd, "y"}, {0xff, "y"}, {0x100, "A"}, {0x101, "a"}, {0x102, "A"}, {0x103, "a"},
    {0x104, "A"}, {0x105, "a"}, {0x106, "C"}, {0x107, "c"}, {0x108, "C"}, {0x109, "c"}, {0x10a, "C"}, {0x10b, "c"},
    {0x10c, "C"}, {0x10d, "c"}, {0x10e, "D"}, {0x10f, "d"}, {0x111, "d"}, {0x112, "E"}, {0x113, "e"}, {0x114, "E"},
    {0x115, "e"}, {0x116, "E"}, {0x117, "e"}, {0x118, "E"}, {0x119, "e"}, {0x11a, "E"}, {0x11b, "e"}, {0x11c, "G"},
    {0x11d, "g"}, {0x11e, "G"}, {0x11f, "g"}, {0x120, "G"}, {0x121, "g"}, {0x122, "G"}, {0x123, "g"}, {0x124, "H"},
    {0x125, "h"}, {0x128, "I"}, {0x129, "i"}, {0x12a, "I"}, {0x12b, "i"}, {0x12c, "I"}, {0x12d, "i"}, {0x12e, "I"},
    {0x12f, "i"}, {0x130, "I"}, {0x131, "i"}, {0x132, "IJ"}, {0x133, "ij"}, {0x134, "J"}, {0x135, "j"},
    {0x136, "K"}, {0x137, "k"}, {0x139, "L"}, {0x13a, "l"}, {0x13b, "L"}, {0x13c, "l"}, {0x13d, "L"}, {0x13e, "l"},
    {0x141, "L"}, {0x142, "l"}, {0x143, "N"}, {0x144, "n"}, {0x145, "N"}, {0x146, "n"}, {0x147, "N"}, {0x148, "n"},
    {0x14c, "O"}, {0x14d, "o"}, {0x14e, "O"}, {0x14f, "o"}, {0x150, "O"}, {0x151, "o"}, {0x154, "R"}, {0x155, "r"},
    {0x156, "R"}, {0x157, "r"}, {0x158, "R"}, {0x159, "r"}, {0x15a, "S"}, {0x15b, "s"}, {0x15c, "S"}, {0x15d, "s"},
    {0x15e, "S"}, {0x15f, "s"}, {0x160, "S"}, {0x161, "s"}, {0x162, "T"}, {0x163, "t"}, {0x164, "T"}, {0x165, "t"},
    {0x168, "U"}, {0x169, "u"}, {0x16a, "U"}, {0x16b, "u"}, {0x16c, "U"}, {0x16d, "u"}, {0x16e, "U"}, {0x16f, "u"},
    {0x170, "U"}, {0x171, "u"}, {0x172, "U"}, {0x173, "u"}, {0x174, "W"}, {0x175, "w"}, {0x176, "Y"}, {0x177, "y"},
    {0x178, "Y"}, {0x179, "Z"}, {0x17a, "z"}, {0x17b, "Z"}, {0x17c, "z"}, {0x17d, "Z"}, {0x17e, "z"}, {0x17f, "s"},
    {0x2009, " "}, {0x2013, "-"}, {0x2014, "-"}, {0x2018, "'"}, {0x2019, "'"}, {0x201a, "'"}, {0x201c, "\""},
    {0x201d, "\""}, {0x201e, "\""}, {0x2026, "..."}, {0x202f, " "}
};

std::string fold(const std::string &text) {
    std::string out;
    for (size_t i = 0; i < text.size();) {
        const auto c = static_cast<unsigned char>(text[i]);
        if (c < 0x80) {
            out += text[i++];
            continue;
        }
        if (c < 0xc0) {  // a character's continuation without its start: the context was cut inside it
            i++;
            continue;
        }
        const int n = c >= 0xf0 ? 4 : c >= 0xe0 ? 3 : 2;
        char32_t cp = c & (0x3f >> (n - 1));
        for (int k = 1; k < n && i + k < text.size(); k++) cp = cp << 6 | (text[i + k] & 0x3f);
        i += n;
        const auto it = std::lower_bound(std::begin(FOLDED), std::end(FOLDED), cp,
                                         [](const auto &f, char32_t v) { return f.first < v; });
        if (it != std::end(FOLDED) && it->first == cp) out += it->second;
    }
    return out;
}

const std::string ALPHABET = "abcdefghijklmnopqrstuvwxyz'";  // the letters a hint can hold

// A word's letters as a hint holds them: lowercase, only ALPHABET's.
std::string hintLetters(const std::string &word) {
    std::string out;
    for (char c : lower(word))
        if (ALPHABET.find(c) != std::string::npos) out += c;
    return out;
}

std::string stripped(std::string s) {
    s.erase(std::remove(s.begin(), s.end(), '\''), s.end());
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
    // Read, not mapped: with the dot product kernels ggml repacks the weights into memory of its own, and the
    // mapped file's pages they were read from stayed resident too, 26 MB more on the phone (#406).
    mp.load_mode = LLAMA_LOAD_MODE_NONE;
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
    for (char c : ALPHABET) {
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
    return tokenize(fold(mWindow), true);
}

const float *Model::advance(const std::vector<int> &prefix) {
    llama_memory_t mem = llama_get_memory(mCtx);
    dropBranches();
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

void Model::dropBranches() {
    llama_memory_t mem = llama_get_memory(mCtx);
    for (int s = 1; s <= mBranches; s++) llama_memory_seq_rm(mem, s, -1, -1);
    mBranches = 0;
}

std::vector<std::vector<int>> Model::branch(const std::vector<std::vector<int>> &followers,
                                           const std::vector<size_t> &from,
                                           const std::vector<std::vector<bool>> &read) {
    // A tree: followers that start alike at the same place share those tokens, decoded once on all their
    // sequences.
    llama_memory_t mem = llama_get_memory(mCtx);
    std::map<std::pair<size_t, std::vector<int>>, int> node;  // a follower's start and first tokens -> their last
                                                              // token's batch index
    std::vector<std::vector<int>> index(followers.size()), seqs;
    std::vector<int> tokens;
    std::vector<size_t> pos;
    std::vector<bool> logits;
    for (size_t i = 0; i < followers.size(); i++) {
        if (followers[i].empty()) continue;
        const size_t start = from.empty() ? mCached.size() : from[i];
        const int seq = ++mBranches;
        llama_memory_seq_cp(mem, 0, seq, 0, start);
        std::pair<size_t, std::vector<int>> path{start, {}};
        for (int t : followers[i]) {
            path.second.push_back(t);
            auto [it, added] = node.emplace(path, tokens.size());
            if (added)
                tokens.push_back(t), pos.push_back(start + path.second.size() - 1), seqs.emplace_back(),
                    logits.push_back(false);
            if (read[i][path.second.size() - 1]) logits[it->second] = true;
            seqs[it->second].push_back(seq);
            index[i].push_back(it->second);
        }
    }
    if (tokens.empty()) return index;
    llama_batch batch = llama_batch_init(tokens.size(), 0, mBranches);
    for (size_t k = 0; k < tokens.size(); k++) {
        batch.token[k] = tokens[k];
        batch.pos[k] = pos[k];
        batch.n_seq_id[k] = seqs[k].size();
        for (size_t j = 0; j < seqs[k].size(); j++) batch.seq_id[k][j] = seqs[k][j];
        batch.logits[k] = logits[k];
    }
    batch.n_tokens = tokens.size();
    const int status = llama_decode(mCtx, batch);
    llama_batch_free(batch);
    if (status != 0) throw std::runtime_error("sebtype-lm: decoding failed");
    return index;
}

Model::Row Model::row(const float *logits) const {
    const float top = *std::max_element(logits, logits + mVocabSize);
    float sum = 0, end = 0;
    int next = -1;
    for (int t = 0; t < mVocabSize; t++) {
        const float p = std::exp(logits[t] - top);
        sum += p;
        if (mEndsWord[t]) end += p;
        else if (next < 0 || logits[t] > logits[next]) next = t;
    }
    return {top, std::log(sum), float(std::log(end / sum)), next};
}

float Model::logSoftmax(const float *logits, int token, const Row &r) { return logits[token] - r.top - r.log; }

std::vector<Word> Model::nextWords(const std::string &context, size_t n) {
    const float *logits = advance(contextTokens(context));
    std::vector<int> first;
    for (int t = 0; t < mVocabSize; t++)
        if (mWordStart[t]) first.push_back(t);
    const size_t k = std::min<size_t>(NEXT_WORD_PIECES, first.size());
    std::partial_sort(first.begin(), first.begin() + k, first.end(),
                      [&](int a, int b) { return logits[a] > logits[b]; });
    first.resize(k);
    struct Path {
        int piece;  // its last
        int seq;    // the sequence that holds its pieces
        int at;     // the batch index of its last piece's logits
        std::string word;
        float logProb;
    };
    std::vector<Path> paths;
    const Row start = row(logits);
    std::vector<std::vector<int>> followers;
    for (size_t i = 0; i < first.size(); i++) {  // branch() numbers its sequences from 1, in order
        paths.push_back({first[i], int(i) + 1, 0, mText[first[i]].substr(1), logSoftmax(logits, first[i], start)});
        followers.push_back({first[i]});
    }
    dropBranches();
    const auto index = branch(followers, {}, std::vector<std::vector<bool>>(first.size(), {true}));
    for (size_t i = 0; i < paths.size(); i++) paths[i].at = index[i][0];

    // Each path is a word that either ends after its last piece or goes on with its likeliest continuation,
    // up to NEXT_WORD_MAX_PIECES: a contraction is 3 pieces (▁don ' t). A path goes on only while it can still
    // beat the Nth word found, as its probability only falls with each piece. A path's next piece is decoded
    // on its own sequence, after the pieces it holds.
    std::vector<Word> words;
    auto nth = [&] {
        if (words.size() < n) return -INFINITY;
        std::vector<float> lp;
        for (const Word &w : words) lp.push_back(w.logProb);
        std::nth_element(lp.begin(), lp.begin() + (n - 1), lp.end(), std::greater<>());
        return lp[n - 1];
    };
    for (int depth = 1; !paths.empty(); depth++) {
        std::vector<Path> longer;
        for (const Path &p : paths) {
            const float *after = llama_get_logits_ith(mCtx, p.at);
            const Row r = row(after);
            // A word can't end in an apostrophe: "don'" is half of "don't".
            if (p.word.back() != '\'') words.push_back({p.word, p.logProb + r.end});
            if (r.next < 0 || depth >= NEXT_WORD_MAX_PIECES) continue;
            Path q{r.next, p.seq, 0, p.word + mText[r.next], p.logProb + logSoftmax(after, r.next, r)};
            // A contraction's ending (n't's t, 's, 'll) ends its word: taken as it is, it saves a decode.
            if (p.word.back() == '\'' && CONTRACTION_ENDS.count(mText[r.next])) words.push_back({q.word, q.logProb});
            else longer.push_back(std::move(q));
        }
        const float bar = nth();
        longer.erase(std::remove_if(longer.begin(), longer.end(), [&](const Path &p) { return p.logProb <= bar; }),
                     longer.end());
        paths = std::move(longer);
        if (paths.empty()) break;
        llama_batch batch = llama_batch_init(paths.size(), 0, 1);
        for (size_t k = 0; k < paths.size(); k++) {
            batch.token[k] = paths[k].piece;
            batch.pos[k] = mCached.size() + depth;
            batch.n_seq_id[k] = 1;
            batch.seq_id[k][0] = paths[k].seq;
            batch.logits[k] = true;
            paths[k].at = k;
        }
        batch.n_tokens = paths.size();
        const int status = llama_decode(mCtx, batch);
        llama_batch_free(batch);
        if (status != 0) throw std::runtime_error("sebtype-lm: decoding failed");
    }
    std::stable_sort(words.begin(), words.end(), [](const Word &a, const Word &b) { return a.logProb > b.logProb; });
    std::vector<Word> out;
    for (Word &w : words) {
        // The pronoun I and its contractions are capitals, however often chats type them small.
        if (w.word == "i" || w.word.rfind("i'", 0) == 0) w.word[0] = 'I';
        const bool seen = std::any_of(out.begin(), out.end(), [&](const Word &o) { return lower(o.word) == lower(w.word); });
        if (!seen && out.size() < n) out.push_back(w);
    }
    return out;
}

std::vector<float> Model::score(const std::string &context, const std::string &typed,
                                const std::vector<std::string> &words, bool typedIsWord,
                                std::vector<float> *asTyped) {
    std::vector<int> prefix = contextTokens(context);
    prefix.push_back(mTypo);
    const size_t hintStart = prefix.size();
    const std::string letters = hintLetters(fold(typed));
    for (char c : letters) prefix.push_back(mLetter[ALPHABET.find(c)]);
    prefix.push_back(mSep);
    const float *logits = advance(prefix);

    // Each word is read after a hint of its own, as in training: <T>, its letters, <S>, its pieces, and then
    // whether it ends there (but see below). The pieces' probabilities are summed; the hints' aren't, nor the
    // next word's start, which its own hint stands for.
    // - A contraction typed without its apostrophe (could've for "couldve"): the keyboard's letters have no
    //   apostrophe to type, so its hint has it, as training's examples of the word nearly always did (#561).
    // - A candidate of several words ("could be" for "couldve"): each further word's hint holds the letters
    //   typed after the word before it ("ve"), so they count against it as they do against a single word.
    const bool capital = sentenceStart(fold(context));
    struct Term {
        int after;  // the follower token whose logits give it, -1 for the hint's <S> in sequence 0
        int token;  // the piece, -1 for the word ending
    };
    std::vector<std::vector<int>> followers(words.size());  // then those that read words without a hint
    std::vector<size_t> from(words.size(), prefix.size());
    std::vector<std::vector<Term>> terms(words.size());
    std::vector<float> out(words.size(), 0);
    std::vector<size_t> contractions;
    std::vector<std::vector<int>> spelt(words.size());  // each word's pieces, without hints
    for (size_t i = 0; i < words.size(); i++) {
        std::vector<int> &f = followers[i];
        size_t used = 0;  // the typed letters the words so far took
        for (size_t start = 0; start <= words[i].size();) {
            const size_t space = std::min(words[i].find(' ', start), words[i].size());
            std::string w = fold(words[i].substr(start, space - start));
            if (start == 0 && capital && !w.empty()) w[0] = std::toupper(static_cast<unsigned char>(w[0]));
            const std::string own = hintLetters(w);
            if (start == 0 && space == words[i].size() && own != letters && own.find('\'') != std::string::npos &&
                stripped(own) == stripped(letters)) {
                // The contraction's hint branches off sequence 0's where its letters part.
                size_t k = 0;
                while (k < own.size() && k < letters.size() && own[k] == letters[k]) k++;
                from[i] = hintStart + k;
                contractions.push_back(i);
                for (char c : own.substr(k)) f.push_back(mLetter[ALPHABET.find(c)]);
                f.push_back(mSep);
            } else if (start > 0 && used < letters.size()) {
                terms[i].push_back({int(f.size()) - 1, -1});
                f.push_back(mTypo);
                for (char c : letters.substr(used)) f.push_back(mLetter[ALPHABET.find(c)]);
                f.push_back(mSep);
            }
            used += own.size();
            const auto pieces = tokenize(w, false);
            if (pieces.empty()) out[i] = -INFINITY;
            for (int t : pieces) terms[i].push_back({int(f.size()) - 1, t}), f.push_back(t);
            spelt[i].insert(spelt[i].end(), pieces.begin(), pieces.end());
            start = space + 1;
        }
    }
    // Where a word ends is read only for the typed word, which the others must beat, and for a word another
    // continues (don, don't): elsewhere it changes little and would cost a decoded token per word, which
    // doubled the time a key takes (#561).
    for (size_t i = 0; i < words.size(); i++) {
        const bool continued = std::any_of(spelt.begin(), spelt.end(), [&](const std::vector<int> &o) {
            return !spelt[i].empty() && o.size() > spelt[i].size() && std::equal(spelt[i].begin(), spelt[i].end(), o.begin());
        });
        if (i + 1 == words.size() || continued) terms[i].push_back({int(followers[i].size()) - 1, -1});
        else if (!followers[i].empty()) followers[i].pop_back();  // its last piece: no term reads after it
    }
    // The keys typed are a contraction's letters as much as the typed word's, so they can't tell the two
    // apart, and the model, which copies a hint it knows, would score the contraction as typed in full in any
    // text. So the two share what their hints together score by the odds the text before gives them: the
    // contraction scores no more than its share, and the typed word no less, so "I feel ill" isn't I'll and
    // "Show your id" is ID, not I'd. Those odds are read without a hint, after the context's last token again.
    // A share and not the typed word's score times the odds: the model scores a rare spelling low after its
    // own hint (whens, hows), and "when" beat both when's and whens (#568). Typed letters that aren't a word
    // share nothing: "I couldve" became "could be".
    auto inText = [&](std::string w) {
        if (capital && !w.empty()) w[0] = std::toupper(static_cast<unsigned char>(w[0]));
        std::vector<int> f{prefix[hintStart - 2]};
        terms.emplace_back();
        for (int t : tokenize(fold(w), false)) terms.back().push_back({int(f.size()) - 1, t}), f.push_back(t);
        terms.back().push_back({int(f.size()) - 1, -1});
        followers.push_back(std::move(f));
        from.push_back(hintStart - 2);
        out.push_back(0);
        return out.size() - 1;
    };
    std::vector<std::pair<size_t, size_t>> typedWords, inTexts;  // (its index in WORDS, its text score's)
    if (!contractions.empty()) {
        for (size_t i = 0; i < words.size(); i++)
            if (words[i].find(' ') == std::string::npos && hintLetters(fold(words[i])) == letters &&
                (typedIsWord || words[i] != typed))
                typedWords.emplace_back(i, inText(words[i]));
        if (!typedWords.empty())
            for (size_t i : contractions) inTexts.emplace_back(i, inText(words[i]));
    }
    // ASTYPED: a contraction read after the typed letters' hint too, as every other word is.
    std::vector<std::pair<size_t, size_t>> plain;  // (its index in WORDS, that reading's)
    if (asTyped && typedIsWord)
        for (size_t i : contractions) {
            terms.emplace_back();
            for (size_t k = 0; k < spelt[i].size(); k++) terms.back().push_back({int(k) - 1, spelt[i][k]});
            terms.back().push_back({int(spelt[i].size()) - 1, -1});
            followers.push_back(spelt[i]);
            from.push_back(prefix.size());
            out.push_back(0);
            plain.emplace_back(i, out.size() - 1);
        }
    // Sequence 0's logits first: branch() decodes over them.
    const Row hint = row(logits);
    for (size_t i = 0; i < terms.size(); i++)
        for (const Term &t : terms[i])
            if (t.after < 0) out[i] += t.token < 0 ? hint.end : logSoftmax(logits, t.token, hint);
    std::vector<std::vector<bool>> read;  // the follower tokens whose logits a term reads
    for (size_t i = 0; i < followers.size(); i++) {
        read.emplace_back(followers[i].size());
        for (const Term &t : terms[i])
            if (t.after >= 0) read[i][t.after] = true;
    }
    const auto index = branch(followers, from, read);
    std::map<int, Row> rows;  // by batch index: words that start alike share their first pieces' rows
    for (size_t i = 0; i < terms.size(); i++)
        for (const Term &t : terms[i]) {
            if (t.after < 0) continue;
            const int at = index[i][t.after];
            const float *after = llama_get_logits_ith(mCtx, at);
            auto it = rows.find(at);
            if (it == rows.end()) it = rows.emplace(at, row(after)).first;
            out[i] += t.token < 0 ? it->second.end : logSoftmax(after, t.token, it->second);
        }
    const std::vector<float> hinted = out;
    if (asTyped) {
        asTyped->assign(hinted.begin(), hinted.begin() + words.size());
        for (const auto &[c, p] : plain) (*asTyped)[c] = hinted[p];
    }
    for (const auto &[c, text] : inTexts)
        for (const auto &[t, typedText] : typedWords) {
            const float both = std::max(hinted[c], hinted[t]) + std::log1p(std::exp(-std::abs(hinted[c] - hinted[t])));
            const float odds = out[text] - out[typedText];
            out[c] = std::min(out[c], both - std::log1p(std::exp(-odds)));
            out[t] = std::max(out[t], both - std::log1p(std::exp(odds)));
        }
    out.resize(words.size());
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
              const std::vector<float> &logProbs, bool typedIsLearned, const std::vector<float> &asTyped) {
    const auto words = rankedWords(typed, candidates);
    auto decoder = [&](const std::string &word) {
        float d = 0;
        for (const Candidate &c : candidates)
            if (c.word == word) d = std::max(d, c.decoderScore);
        return std::max(d, MIN_DECODER_SCORE);
    };
    const float typedDecoder = std::min(decoder(typed), MAX_DECODER_SCORE);
    std::vector<float> score(words.size());
    score.back() = logProbs.back() + DECODER_WEIGHT * std::log(typedDecoder);
    const std::string letters = hintLetters(fold(typed));
    for (size_t i = 0; i + 1 < words.size(); i++) {
        score[i] = logProbs[i] + DECODER_WEIGHT * std::log(std::min(decoder(words[i]), MAX_DECODER_SCORE));
        // A contraction of a typed dictionary word's letters (cant: can't). The keys score the two alike, and
        // the decoder's far higher score for it is the dictionary's shortcut, which outweighed what the text
        // says ("I despise such cant", #568). So it takes the typed word's decoder score. It is still corrected
        // to as before #561, read after the typed letters' hint with the shortcut's score ("I cant"), but only
        // if read after its own hint it is the likelier of the two: "as is his wont" stays.
        const std::string own = hintLetters(fold(words[i]));
        if (!typedIsWord || own == letters || own.find('\'') == std::string::npos || stripped(own) != letters)
            continue;
        score[i] = logProbs[i] + DECODER_WEIGHT * std::log(typedDecoder);
        if (!asTyped.empty() && logProbs[i] > logProbs.back())
            score[i] = std::max(score[i], score.back() + asTyped[i] - asTyped.back() +
                                              DECODER_WEIGHT * std::log(decoder(words[i]) / typedDecoder));
    }
    std::vector<size_t> order(words.size() - 1);  // the typed word is last
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return score[a] > score[b]; });
    Ranked out{{}, typed};
    for (size_t i : order) out.strip.push_back(words[i]);
    const float margin = typedIsWord ? MARGIN_WORD : MARGIN_NON_WORD;
    // One letter is corrected only to its capital (i to I), and a word only learned never: the model hasn't
    // seen it, so it would lose to any likely word (#555).
    if (!order.empty() && !typedIsLearned && (typed.size() > 1 || lower(words[order[0]]) == lower(typed)) &&
        score[order[0]] - score.back() > margin)
        out.committed = words[order[0]];
    return out;
}

}  // namespace sebtype_lm
