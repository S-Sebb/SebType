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
constexpr size_t NEXT_WORDS_SHOWN = 3;   // the words the strip shows, which a path must be able to beat
constexpr size_t SCORED_CANDIDATES = 6;
// decide()'s weights, tuned on tools/english-lm's own dev sets (tune.py), never on the harness's test sets.
// MARGIN_NON_WORD: 10 changes no more dev words than 12 did; the harness's clean words changed 0.2 -> 0.3 %, accepted
// for 12 points more misspellings fixed (#291).
constexpr float DECODER_WEIGHT = 1.5f;  // of the log of the decoder's normalised score
constexpr float MIN_DECODER_SCORE = 1e-3f;
// The dictionary's shortcuts (ill -> I'll, cant -> can't) score about 1,600 where a word typed exactly scores
// under 2: uncapped, they outweighed whatever the text before says ("I feel ill", "Show your id"). Applied where
// the typed letters are a word, and to a shortcut a typo reached; chosen on #561's contraction and homograph
// probe, and kept on r4, where 1 to 20 moved at most 4 of its 2,700 rows (#556).
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

// Whether OWN, a word's hint letters with an apostrophe, is a common contraction: n't, 're, 've, 'll or 'd, I'm,
// 's after a pronoun or a question word, o'clock, y'all or ma'am. Not a possessive (goo's) nor a rare form (h'm,
// ne'er): as the only correction of letters that aren't a word, they took hm, goos and neer, which main kept or
// corrected (#568).
bool common(const std::string &own) {
    static const std::set<std::string> ends = {"re", "ve", "ll", "d"};
    static const std::set<std::string> is = {"it", "he", "she", "that", "there", "here", "what", "where", "when",
                                             "why", "how", "who", "let", "this", "everyone", "everybody",
                                             "someone", "somebody", "nobody", "one"};
    const auto at = own.rfind('\'');
    const std::string stem = own.substr(0, at), end = own.substr(at + 1);
    return (end == "t" && !stem.empty() && stem.back() == 'n') || ends.count(end) || (end == "m" && stem == "i") ||
           (end == "s" && is.count(stem)) || own == "o'clock" || own == "y'all" || own == "ma'am";
}

// Whether WORD, a candidate as the decoder gives it, is a common contraction of the hint's LETTERS: one word,
// they and an apostrophe. Not a name's possessive ("What eas": Ea's), nor words apart ("towords": to word's).
bool contractionOf(const std::string &word, const std::string &letters) {
    const std::string own = hintLetters(fold(word));
    return word.find(' ') == std::string::npos && (!std::isupper(static_cast<unsigned char>(word[0])) ||
                                                    word.rfind("I'", 0) == 0) &&
           own != letters && own.find('\'') != std::string::npos && stripped(own) == stripped(letters) &&
           common(own);
}

// Whether WORD is in capitals: more than one letter, none small. A quote or an apostrophe isn't a letter ("I).
bool capitals(const std::string &w) {
    const auto upper = std::count_if(w.begin(), w.end(), [](unsigned char c) { return std::isupper(c); });
    return upper > 1 && std::none_of(w.begin(), w.end(), [](unsigned char c) { return std::islower(c); });
}

// The last word of folded TEXT's last line, the line the model reads.
std::string lastWord(const std::string &text) {
    std::string s = text.substr(0, text.find_last_not_of(' ') + 1);  // npos + 1: none
    s = s.substr(s.rfind('\n') + 1);
    return s.substr(s.rfind(' ') + 1);
}

// Whether folded TEXT ends in text in capitals, which the model reads in small letters: its last line's last
// word in capitals after I or another word in capitals ("I THINK", "I FEEL ILL"), or holding an apostrophe
// (DON'T). A lone acronym (OK, LOL, USA) or a quoted I (“I) isn't such text: read small, OK's next words were
// BECAUSE, BUT (#568).
bool shoutedText(const std::string &text) {
    const std::string last = lastWord(text);
    const std::string before = lastWord(text.substr(0, text.find_last_not_of(' ') + 1 - last.size()));
    return capitals(last) &&
           (hintLetters(before) == "i" || capitals(before) || last.find('\'') != std::string::npos);
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
    mWindow = window(fold(context));  // folded first: a no-break space at the end is a space window() drops
    return tokenize(mWindow, true);
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
    if (n == 0) return {};
    // Text in capitals ("I THINK", "DON'T") is read in small letters, as score() reads it, and its next words
    // are shown in capitals: read as it is, they were pieces of words (OF, E, T).
    const std::string folded = fold(context);
    const bool shouted = shoutedText(folded);
    const float *logits = advance(contextTokens(shouted ? lower(folded) : context));
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
        int stem = -1;  // the word in WORDS it goes on from, if it is likelier than that word
    };
    std::vector<Path> paths;
    const Row start = row(logits);
    std::vector<std::vector<int>> followers;
    for (size_t i = 0; i < first.size(); i++) {  // branch() numbers its sequences from 1, in order
        paths.push_back({first[i], int(i) + 1, 0, mText[first[i]].substr(1), logSoftmax(logits, first[i], start)});
        followers.push_back({first[i]});
    }
    const auto index = branch(followers, {}, std::vector<std::vector<bool>>(first.size(), {true}));
    for (size_t i = 0; i < paths.size(); i++) paths[i].at = index[i][0];

    // Each path is a word that either ends after its last piece or goes on with its likeliest continuation,
    // up to NEXT_WORD_MAX_PIECES: a contraction is 3 pieces (▁don ' t). A path goes on only while it can still
    // beat the words the strip shows, as its probability only falls with each piece; the others are a reserve
    // for the keyboard's filters, found without decoding further (5th: 82 of 500 chat rows decoded more rounds,
    // and next-word p95 was 6 ms above main's, #568). A path's next piece is decoded on its own sequence, after
    // the pieces it holds. A word whose likelier reading is a longer word left unfinished isn't offered: "don"
    // where don't was meant.
    std::vector<Word> words;
    const size_t shown = std::min(n, NEXT_WORDS_SHOWN);
    auto nth = [&] {
        if (words.size() < shown) return -INFINITY;
        std::vector<float> lp;
        for (const Word &w : words) lp.push_back(w.logProb);
        std::nth_element(lp.begin(), lp.begin() + (shown - 1), lp.end(), std::greater<>());
        return lp[shown - 1];
    };
    for (int depth = 1; !paths.empty(); depth++) {
        std::vector<Path> longer;
        for (const Path &p : paths) {
            const float *after = llama_get_logits_ith(mCtx, p.at);
            const Row r = row(after);
            // A word can't end in an apostrophe: "don'" is half of "don't".
            if (p.word.back() != '\'') words.push_back({p.word, p.logProb + r.end});
            if (r.next < 0 || depth >= NEXT_WORD_MAX_PIECES) continue;
            Path q{r.next, p.seq, 0, p.word + mText[r.next], p.logProb + logSoftmax(after, r.next, r), p.stem};
            if (p.word.back() != '\'') q.stem = q.logProb > words.back().logProb ? int(words.size()) - 1 : -1;
            // A contraction's ending (n't's t, 's, 'll) ends its word: taken as it is, it saves a decode. It
            // then skips the end-of-word term the other words pay, which, read, changed 2 of 7,246 next-word
            // rows and no target in the top 3 (#568).
            if (p.word.back() == '\'' && CONTRACTION_ENDS.count(mText[r.next])) {
                words.push_back({q.word, q.logProb});
                // Its stem, if the stem as a word was the less likely reading, is half of it: "don" for don't.
                if (q.stem >= 0) words[q.stem].logProb = -INFINITY;
            } else longer.push_back(std::move(q));
        }
        const float bar = nth();
        longer.erase(std::remove_if(longer.begin(), longer.end(), [&](const Path &p) {
                         if (p.logProb > bar) return false;
                         if (p.stem >= 0) words[p.stem].logProb = -INFINITY;
                         return true;
                     }),
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
        if (shouted)
            for (char &c : w.word) c = std::toupper(static_cast<unsigned char>(c));
        const bool seen = std::any_of(out.begin(), out.end(), [&](const Word &o) { return lower(o.word) == lower(w.word); });
        if (!seen && out.size() < n && w.logProb > -INFINITY) out.push_back(w);
    }
    return out;
}

std::vector<float> Model::score(const std::string &context, const std::string &typed,
                                const std::vector<std::string> &words, bool typedIsWord,
                                std::vector<float> *asTyped, bool typedKept, float *typedEnd) {
    // Letters typed in capitals are read in small letters, as the model knows words best, and so is the text
    // before when its last word is in capitals too: "I FEEL ILL" as "i feel ill", "I SAID WHATS" as "i said
    // whats". Read in capitals the model hardly knows a contraction (WHAT'S), and with ill in small letters
    // after "I FEEL" it read I'll (#568). Other words are capitalised where a sentence starts or as typed.
    const std::string typedText = fold(typed), folded = fold(context);
    const bool shouted = capitals(typedText), textShouted = shouted && shoutedText(folded + " " + typedText);
    const bool typedCapital = !typedText.empty() && std::isupper(static_cast<unsigned char>(typedText[0]));
    const bool capital = !textShouted && (sentenceStart(folded) || (typedCapital && !shouted));
    auto shown = [&](std::string w, bool first) {
        if (shouted && w == typedText) w = lower(w);
        if (first && capital && !w.empty()) w[0] = std::toupper(static_cast<unsigned char>(w[0]));
        return w;
    };

    std::vector<int> prefix = contextTokens(textShouted ? lower(folded) : context);
    prefix.push_back(mTypo);
    const size_t hintStart = prefix.size();
    const std::string letters = hintLetters(typedText);
    for (char c : letters) prefix.push_back(mLetter[ALPHABET.find(c)]);
    prefix.push_back(mSep);
    const float *logits = advance(prefix);

    // Each word is read after the typed letters' hint, as in training: <T>, the letters, <S>, its pieces, and
    // then whether it ends there (but see below). The pieces' probabilities are summed; the hint's isn't, nor
    // the next word's start, which the hint stands for. A contraction too (could've for "couldve"): r4 was
    // trained on contractions typed without their apostrophe, as the keyboard's letters have none (#556). r2
    // wasn't, and read it after a hint with its apostrophe; on r4 that hint fixes one contraction fewer (#561).
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
        for (size_t start = 0; start <= words[i].size();) {
            const size_t space = std::min(words[i].find(' ', start), words[i].size());
            const std::string w = shown(fold(words[i].substr(start, space - start)), start == 0);
            if (start == 0 && contractionOf(words[i], letters)) contractions.push_back(i);
            const auto pieces = tokenize(w, false);
            if (pieces.empty()) out[i] = -INFINITY;
            for (int t : pieces) terms[i].push_back({int(f.size()) - 1, t}), f.push_back(t);
            spelt[i].insert(spelt[i].end(), pieces.begin(), pieces.end());
            start = space + 1;
        }
    }
    // Where a word ends is read only for the typed word, which the others must beat, and for a word another
    // continues (don, don't): elsewhere it changes little and would cost a decoded token per word, which
    // doubled the time a key takes (#561). A typed word kept whatever it scores needs it only where a
    // contraction shares with it. A word another continues pays only for the pieces that continue it to those
    // words, not for any longer word: profession paid for professional's odds, which professional itself, read
    // whole, didn't, and "proffession" became professional where main kept profession (#568).
    const bool typedEnds = !typedKept || !contractions.empty();
    auto starts = [](const std::vector<int> &a, const std::vector<int> &b) {
        return !a.empty() && b.size() > a.size() && std::equal(a.begin(), a.end(), b.begin());
    };
    std::vector<std::set<int>> goesOn(words.size());  // the pieces that continue each word to another
    for (size_t i = 0; i < words.size(); i++)
        for (const std::vector<int> &o : spelt)
            if (starts(spelt[i], o)) goesOn[i].insert(o[spelt[i].size()]);
    auto ending = [&](size_t i, const float *logits, const Row &r) {
        if (i + 1 >= words.size()) return r.end;  // the typed word, and the readings below
        float p = 0;
        for (int t : goesOn[i]) p += std::exp(logSoftmax(logits, t, r));
        return std::log1p(-std::min(p, 0.999f));
    };
    for (size_t i = 0; i < words.size(); i++) {
        const bool continued = !goesOn[i].empty();
        if ((i + 1 == words.size() && typedEnds) || continued)
            terms[i].push_back({int(followers[i].size()) - 1, -1});
        else if (!followers[i].empty()) followers[i].pop_back();  // its last piece: no term reads after it
    }
    // The keys typed are a contraction's letters as much as the typed word's, so they can't tell the two
    // apart, and the model, which copies a hint it knows, would score the contraction as typed in full in any
    // text. So the two share what their hints together score by the odds the text before gives them: the
    // contraction scores no more than its share, and the typed word no less, so "I feel ill" isn't I'll and
    // "Show your id" is ID, not I'd. Those odds are read without a hint, after the context's last token again.
    // A share and not the typed word's score times the odds: the model scores a rare spelling low after its
    // hint (whens, hows), and "when" beat both when's and whens (#568). Typed letters that aren't a word
    // share nothing: "I couldve" became "could be".
    // Other candidates whose letters are the same but for an apostrophe (were, we're for "wer"; years, year's
    // for "yeras") share the same way: the keys can't tell them apart either, and r4, trained on contractions
    // typed without theirs, read the one with an apostrophe likelier after nearly any letters, so a plural
    // typo became a possessive ("steriods": steroid's) and "Why wer" we're (#556).
    auto inText = [&](const std::string &w) {
        std::vector<int> f{prefix[hintStart - 2]};
        terms.emplace_back();
        for (int t : tokenize(shown(fold(w), true), false))
            terms.back().push_back({int(f.size()) - 1, t}), f.push_back(t);
        terms.back().push_back({int(f.size()) - 1, -1});
        followers.push_back(std::move(f));
        from.push_back(hintStart - 2);
        out.push_back(0);
        return out.size() - 1;
    };
    struct Share {
        std::vector<std::pair<size_t, size_t>> capped, raised;  // (its index in WORDS, its text score's)
    };
    std::vector<Share> shares;
    if (!contractions.empty()) {
        Share s;
        for (size_t i = 0; i < words.size(); i++)
            if (words[i].find(' ') == std::string::npos && hintLetters(fold(words[i])) == letters &&
                (typedIsWord || words[i] != typed))
                s.raised.emplace_back(i, inText(words[i]));
        if (!s.raised.empty()) {
            for (size_t i : contractions) s.capped.emplace_back(i, inText(words[i]));
            shares.push_back(std::move(s));
        }
    }
    std::map<std::string, std::vector<size_t>> sameLetters;
    for (size_t i = 0; i + 1 < words.size(); i++)
        if (words[i].find(' ') == std::string::npos && out[i] > -INFINITY)
            sameLetters[stripped(hintLetters(fold(words[i])))].push_back(i);
    const auto apostrophe = [&](size_t i) { return words[i].find('\'') != std::string::npos; };
    for (const auto &[key, group] : sameLetters)
        if (key != stripped(letters) && std::any_of(group.begin(), group.end(), apostrophe) &&
            !std::all_of(group.begin(), group.end(), apostrophe)) {
            Share s;
            for (size_t i : group) (apostrophe(i) ? s.capped : s.raised).emplace_back(i, inText(words[i]));
            shares.push_back(std::move(s));
        }
    // Sequence 0's logits first: branch() decodes over them.
    const Row hint = row(logits);
    for (size_t i = 0; i < terms.size(); i++)
        for (const Term &t : terms[i])
            if (t.after < 0) out[i] += t.token < 0 ? ending(i, logits, hint) : logSoftmax(logits, t.token, hint);
    float end = 0;  // the typed word's ending term
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
            out[i] += t.token < 0 ? ending(i, after, it->second) : logSoftmax(after, t.token, it->second);
            if (t.token < 0 && i + 1 == words.size()) end = it->second.end;
        }
    if (typedEnd) *typedEnd = end;
    const std::vector<float> hinted = out;
    if (asTyped) asTyped->assign(hinted.begin(), hinted.begin() + words.size());
    // One share for all of them: shared pair by pair, the typed word and the same word in other capitals
    // ("Show your id": ID) each took nearly all of I'd's score, and so tied (#568).
    for (const auto &[capped, raised] : shares) {
        const auto logSum = [](const std::vector<float> &v) {
            const float top = *std::max_element(v.begin(), v.end());
            float sum = 0;
            for (float x : v) sum += std::exp(x - top);
            return top + std::log(sum);
        };
        std::vector<float> hints, texts;
        for (const auto &group : {capped, raised})
            for (const auto &[i, text] : group) hints.push_back(hinted[i]), texts.push_back(out[text]);
        const float both = logSum(hints), all = logSum(texts);
        for (const auto &[c, text] : capped) out[c] = std::min(out[c], both + out[text] - all);
        for (const auto &[t, text] : raised) out[t] = std::max(out[t], both + out[text] - all);
    }
    out.resize(words.size());
    // A word typed in capitals alone, not in text in capitals, whose letters are a word, is that word: an
    // acronym or a stressed word (ID, ILL), not a contraction shouted (I'D, I'LL).
    if (shouted && !textShouted && typedIsWord)
        for (size_t i : contractions) out[i] = -INFINITY;
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
              const std::vector<float> &logProbs, bool typedIsLearned, const std::vector<float> &asTyped,
              float typedEnd) {
    const auto words = rankedWords(typed, candidates);
    auto decoder = [&](const std::string &word) {
        float d = 0;
        for (const Candidate &c : candidates)
            if (c.word == word) d = std::max(d, c.decoderScore);
        return std::max(d, MIN_DECODER_SCORE);
    };
    // The decoder's score is capped where the typed letters are a word: else the dictionary's shortcuts (I'll,
    // can't: about 1,600) outweigh the context for them. For letters that aren't a word a shortcut is the
    // correction meant ("alot": a lot), as before #561.
    const float cap = typedIsWord ? MAX_DECODER_SCORE : INFINITY;
    const float typedDecoder = std::min(decoder(typed), cap);
    std::vector<float> score(words.size());
    score.back() = logProbs.back() + DECODER_WEIGHT * std::log(typedDecoder);
    const std::string letters = hintLetters(fold(typed));
    auto contraction = [&](size_t i) { return contractionOf(words[i], letters); };
    const auto upper = [](char c) { return std::isupper(static_cast<unsigned char>(c)) != 0; };
    const bool titled = upper(typed[0]) && std::none_of(typed.begin() + 1, typed.end(), upper);  // "Id", not "ID"
    std::vector<float> commit(words.size(), -INFINITY);  // what a space may correct to, by its score
    bool contractions = false;
    for (size_t i = 0; i + 1 < words.size(); i++) contractions |= contraction(i);
    // The typed letters' likeliest word in any capitals (id, ID), which took the contraction's share with it.
    float typedBest = logProbs.back();
    for (size_t i = 0; i + 1 < words.size(); i++)
        if (lower(words[i]) == lower(typed)) typedBest = std::max(typedBest, logProbs[i]);
    for (size_t i = 0; i + 1 < words.size(); i++) {
        // A shortcut is the dictionary's for its own letters (alot: a lot, itd: it'd); reached by a typo, its
        // score is capped as for a typed word ("Why wer": the shortcut were -> we're, #556).
        const bool ownLetters = stripped(hintLetters(fold(words[i]))) == stripped(letters);
        score[i] = logProbs[i] + DECODER_WEIGHT * std::log(std::min(decoder(words[i]), ownLetters ? cap : MAX_DECODER_SCORE));
        if (!typedIsWord || !contraction(i)) {
            // Typed letters that aren't a word but are a contraction's are that contraction or as typed: read
            // as a word's start, "shant" became shanty, which the model, as yet, finds the likelier (#568).
            if (typedIsWord || !contractions || contraction(i)) commit[i] = score[i];
            // A word is weighed against the typed word without its ending: the space says the typed word ends
            // there, and the model, which can't know that, put the odds of the words it starts in that ending
            // ("Sure, hell": hello; "my fiance": finance; impl: imply), where main kept them (#568). The same word
            // in other capitals ends where the typed word does ("The Id", "Enter your id": ID), if the typed
            // letters are a word: else, unpaid, it won where another word was meant ("Pretend you ste": Ste).
            if (!typedIsWord || lower(words[i]) != lower(typed)) commit[i] += typedEnd;
            continue;
        }
        // A contraction of a typed dictionary word's letters (cant: can't). The keys score the two alike, and
        // the decoder's far higher score for it is the dictionary's shortcut, which outweighed what the text
        // says ("I despise such cant", #568). So it takes the typed word's decoder score, which places it in
        // the strip. A space corrects to it only as before #561, read after the typed letters' hint with the
        // shortcut's score ("I cant"), and only if, shared, it is likelier than the typed letters' words in any
        // capitals: "as is his wont" stays, and so does "Were" where a sentence starts, and "Bring your photo
        // id" is ID, which took the share from id. It is weighed against the typed word with its ending:
        // without, "If I were you id" stayed id (#568).
        score[i] = logProbs[i] + DECODER_WEIGHT * std::log(typedDecoder);
        if (!asTyped.empty() && logProbs[i] > typedBest) {
            commit[i] = score.back() + asTyped[i] - asTyped.back() +
                        DECODER_WEIGHT * std::log(decoder(words[i]) / typedDecoder);
            score[i] = std::max(score[i], commit[i]);
        }
    }
    std::vector<size_t> order(words.size() - 1);  // the typed word is last
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return score[a] > score[b]; });
    Ranked out{{}, typed};
    for (size_t i : order) out.strip.push_back(words[i]);
    const auto best = std::max_element(commit.begin(), commit.end() - 1) - commit.begin();
    // Typed letters that aren't a word but are a contraction's are that contraction ("Please dont", "so Dont"):
    // the model reads them as likely as it after their hint, and they fell short of the margin (#568).
    // The typed word in other capitals after a typed first capital alone ("The Id": ID) needs no margin: that
    // capital says a name or an acronym may be meant. Typed in small letters ("the turkey", "ok"), or with
    // capitals inside (DeShawn), it needs the margin any other word does (#568).
    const bool oneLetter = std::count_if(typed.begin(), typed.end(), [](char c) { return (c & 0xc0) != 0x80; }) == 1;
    const bool sameWord = lower(words[best]) == lower(typed), recased = !oneLetter && sameWord;
    const float margin = recased && titled              ? 0
                         : !typedIsWord && contractions ? 0
                         : typedIsWord                 ? MARGIN_WORD
                                                       : MARGIN_NON_WORD;
    // One letter is corrected only to its capital (i to I), and a word only learned never: the model hasn't
    // seen it, so it would lose to any likely word (#555).
    if (!order.empty() && !typedIsLearned && (!oneLetter || sameWord) &&
        commit[best] - score.back() > margin)
        out.committed = words[best];
    return out;
}

}  // namespace sebtype_lm
