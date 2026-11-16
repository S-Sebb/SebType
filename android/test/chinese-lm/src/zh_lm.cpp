// SebType's Chinese model on llama.cpp's public API (llama.h). The model's text format is tools/chinese-lm's
// (pack.py): <s> text, and a pinyin example "<T>typed letters<S>text<E>" in front of the text it types.
// MIT, SebType.
#include "zh_lm.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <mutex>
#include <stdexcept>

#include "llama.h"

namespace zh_lm {
namespace {

constexpr size_t CONTEXT_CHARS = 64;  // the field's text before the cursor the model reads, at most
constexpr int MAX_BRANCHES = 48;  // also at least twice generate()'s width
constexpr int NEXT_FIRST = 8;   // first characters nextWords() follows
constexpr int NEXT_BEAM = 6;    // word prefixes it keeps at each length
constexpr int NEXT_MAX = 4;     // characters in a next word, at most

char32_t codepoint(const std::string &s) {
    if (s.empty()) return 0;
    const unsigned char c = s[0];
    if (c < 0x80) return c;
    if ((c >> 5) == 6 && s.size() >= 2) return ((c & 0x1f) << 6) | (s[1] & 0x3f);
    if ((c >> 4) == 14 && s.size() >= 3) return ((c & 0x0f) << 12) | ((s[1] & 0x3f) << 6) | (s[2] & 0x3f);
    return 0;
}

bool han(char32_t c) { return (c >= 0x3400 && c <= 0x4dbf) || (c >= 0x4e00 && c <= 0x9fff); }

// The last N characters of S (UTF-8).
std::string lastChars(const std::string &s, size_t n) {
    size_t i = s.size(), count = 0;
    while (i > 0 && count < n) {
        --i;
        if ((static_cast<unsigned char>(s[i]) & 0xc0) != 0x80) count++;
    }
    return s.substr(i);
}

float logSigmoid(float x) { return x >= 0 ? -std::log1p(std::exp(-x)) : x - std::log1p(std::exp(x)); }

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
    if (!mModel) throw std::runtime_error("zh-lm: can't load " + path);
    auto cp = llama_context_default_params();
    cp.n_ctx = 1024;
    cp.n_batch = cp.n_ubatch = 512;
    cp.n_seq_max = MAX_BRANCHES + 1;
    cp.n_threads = cp.n_threads_batch = threads;
    cp.kv_unified = true;
    cp.no_perf = true;
    mCtx = llama_init_from_model(mModel, cp);
    if (!mCtx) throw std::runtime_error("zh-lm: can't make a context for " + path);
    mVocab = llama_model_get_vocab(mModel);
    mVocabSize = llama_vocab_n_tokens(mVocab);
    mBos = llama_vocab_bos(mVocab);

    std::map<std::string, int> byText;
    mHan.resize(mVocabSize);
    mText.resize(mVocabSize);
    for (int t = 0; t < mVocabSize; t++) {
        const std::string raw = llama_vocab_get_text(mVocab, t);
        byText.emplace(raw, t);
        char buf[64];
        const int n = llama_token_to_piece(mVocab, t, buf, sizeof buf, 0, true);
        mText[t] = n > 0 ? std::string(buf, n) : "";
        const bool control = llama_vocab_is_control(mVocab, t) || llama_vocab_is_eog(mVocab, t);
        mHan[t] = !control && han(codepoint(mText[t])) && mText[t].size() == 3;
    }
    auto id = [&](const std::string &s) {
        auto it = byText.find(s);
        if (it == byText.end()) throw std::runtime_error("zh-lm: no piece " + s + ": not SebType's Chinese model");
        return it->second;
    };
    mT = id("<T>"), mS = id("<S>"), mE = id("<E>"), mB = id("<B>");
    for (char c = 'a'; c <= 'z'; c++) mLetter.push_back(id(std::string(1, c)));
}

Model::~Model() {
    if (mCtx) llama_free(mCtx);
    if (mModel) llama_model_free(mModel);
}

std::vector<int> Model::tokenize(const std::string &text) const {
    std::vector<int> out(text.size() + 2);
    int n = llama_tokenize(mVocab, text.data(), text.size(), out.data(), out.size(), false, false);
    if (n < 0) {
        out.resize(-n);
        n = llama_tokenize(mVocab, text.data(), text.size(), out.data(), out.size(), false, false);
    }
    out.resize(std::max(n, 0));
    return out;
}

std::vector<int> Model::contextTokens(const std::string &context) const {
    const auto nl = context.rfind('\n');
    std::vector<int> out{mBos};
    const auto text = tokenize(lastChars(nl == std::string::npos ? context : context.substr(nl + 1), CONTEXT_CHARS));
    out.insert(out.end(), text.begin(), text.end());
    return out;
}

std::vector<int> Model::examplePrefix(const std::string &context, const std::string &typed) const {
    std::vector<int> prefix = contextTokens(context);
    prefix.push_back(mT);
    for (char c : typed)
        if (c >= 'a' && c <= 'z') prefix.push_back(mLetter[c - 'a']);
    prefix.push_back(mS);
    return prefix;
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
            throw std::runtime_error("zh-lm: decoding failed");
        }
    }
    llama_batch_free(batch);
    mCached = prefix;
    return llama_get_logits_ith(mCtx, -1);
}

std::vector<std::vector<int>> Model::branch(const std::vector<std::vector<int>> &followers) {
    llama_memory_t mem = llama_get_memory(mCtx);
    for (int s = 1; s <= mBranches; s++) llama_memory_seq_rm(mem, s, -1, -1);
    mBranches = 0;
    std::map<std::vector<int>, int> node;
    std::vector<std::vector<int>> index(followers.size()), seqs;
    std::vector<int> tokens;
    std::vector<size_t> depth;
    for (size_t i = 0; i < followers.size(); i++) {
        if (followers[i].empty()) continue;
        if (mBranches == MAX_BRANCHES) throw std::runtime_error("zh-lm: too many branches");
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
    if (status != 0) throw std::runtime_error("zh-lm: decoding failed");
    return index;
}

float Model::logNorm(const float *logits) const {
    float top = -INFINITY;
    for (int t = 0; t < mVocabSize; t++)
        if (t != mB) top = std::max(top, logits[t]);
    double sum = 0;
    for (int t = 0; t < mVocabSize; t++)
        if (t != mB) sum += std::exp(logits[t] - top);
    return top + std::log(sum);
}

float Model::logEnd(const float *logits) const { return logSigmoid(logits[mB]); }

std::vector<float> Model::score(const std::string &context, const std::string &typed,
                                const std::vector<std::string> &texts) {
    const float *logits = advance(examplePrefix(context, typed));
    const float norm = logNorm(logits);
    std::vector<std::vector<int>> pieces;
    std::vector<float> out;
    for (const auto &text : texts) {
        pieces.push_back(tokenize(text));
        pieces.back().push_back(mE);
        out.push_back(logits[pieces.back()[0]] - norm);
    }
    std::vector<std::vector<int>> followers;
    for (const auto &p : pieces) followers.emplace_back(p.begin(), p.end() - 1);
    const auto index = branch(followers);
    for (size_t i = 0; i < pieces.size(); i++)
        for (size_t j = 0; j < index[i].size(); j++) {
            const float *l = llama_get_logits_ith(mCtx, index[i][j]);
            out[i] += l[pieces[i][j + 1]] - logNorm(l);
        }
    return out;
}

void Model::prime(const std::string &context) { advance(contextTokens(context)); }

std::vector<Text> Model::generate(const std::string &context, const std::string &typed, int width, int maxChars) {
    // Each beam lives on a sequence of its own in the cache: a step copies its parent's (cells are shared) and
    // decodes one token, so a step costs WIDTH tokens. Steps use sequences 1..WIDTH and WIDTH+1..2*WIDTH in turn.
    struct Beam {
        std::vector<int> tokens;
        float logProb;
        int seq;
    };
    const auto prefix = examplePrefix(context, typed);
    const float *first = advance(prefix);
    llama_memory_t mem = llama_get_memory(mCtx);
    mBranches = 2 * width;  // the next advance() or branch() clears them
    std::vector<Beam> beams{{{}, 0, 0}};
    std::vector<const float *> logits{first};
    std::vector<Text> done;
    llama_batch batch = llama_batch_init(width, 0, 1);
    for (int step = 0; step <= maxChars && !beams.empty(); step++) {
        struct Option {
            size_t beam;
            int token;
            float logProb;
        };
        std::vector<Option> options;
        for (size_t i = 0; i < beams.size(); i++) {
            const float *l = logits[i];
            const float norm = logNorm(l);
            std::vector<int> top;
            for (int t = 0; t < mVocabSize; t++)
                if (mHan[t] || t == mE) top.push_back(t);
            const size_t k = std::min<size_t>(width, top.size());
            std::partial_sort(top.begin(), top.begin() + k, top.end(), [&](int a, int b) { return l[a] > l[b]; });
            for (size_t j = 0; j < k; j++) {
                const float lp = beams[i].logProb + l[top[j]] - norm;
                if (top[j] != mE) {
                    if (step < maxChars) options.push_back({i, top[j], lp});
                } else if (!beams[i].tokens.empty()) {
                    std::string text;
                    for (int t : beams[i].tokens) text += mText[t];
                    done.push_back({text, lp});
                }
            }
        }
        std::sort(options.begin(), options.end(), [](const Option &a, const Option &b) { return a.logProb > b.logProb; });
        if (options.size() > static_cast<size_t>(width)) options.resize(width);
        std::sort(done.begin(), done.end(), [](const Text &a, const Text &b) { return a.logProb > b.logProb; });
        // Extending a beam only lowers its probability: stop once WIDTH finished ones beat every beam left.
        if (options.empty() || (static_cast<int>(done.size()) >= width && done[width - 1].logProb > options[0].logProb)) break;
        const int base = step % 2 ? width + 1 : 1;
        std::vector<Beam> next;
        batch.n_tokens = 0;
        for (size_t j = 0; j < options.size(); j++) {
            const Beam &parent = beams[options[j].beam];
            const int seq = base + static_cast<int>(j);
            llama_memory_seq_rm(mem, seq, -1, -1);
            llama_memory_seq_cp(mem, parent.seq, seq, -1, -1);
            next.push_back({parent.tokens, options[j].logProb, seq});
            next.back().tokens.push_back(options[j].token);
            const int k = batch.n_tokens++;
            batch.token[k] = options[j].token;
            batch.pos[k] = prefix.size() + parent.tokens.size();
            batch.n_seq_id[k] = 1;
            batch.seq_id[k][0] = seq;
            batch.logits[k] = true;
        }
        for (const Beam &b : beams)
            if (b.seq != 0) llama_memory_seq_rm(mem, b.seq, -1, -1);
        if (llama_decode(mCtx, batch) != 0) {
            llama_batch_free(batch);
            throw std::runtime_error("zh-lm: decoding failed");
        }
        beams = std::move(next);
        logits.clear();
        for (size_t j = 0; j < beams.size(); j++) logits.push_back(llama_get_logits_ith(mCtx, j));
    }
    llama_batch_free(batch);
    if (done.size() > static_cast<size_t>(width)) done.resize(width);
    return done;
}

std::vector<Text> Model::nextWords(const std::string &context, size_t n) {
    // Word prefixes, NEXT_BEAM at each length, each on a sequence of its own as in generate(): a length costs
    // one token per prefix.
    struct Prefix {
        std::vector<int> tokens;
        float logProb;  // of its characters, and of no word ending inside it
        int seq;
    };
    const auto ctx = contextTokens(context);
    const float *first = advance(ctx);
    llama_memory_t mem = llama_get_memory(mCtx);
    mBranches = 2 * NEXT_BEAM;
    std::vector<Prefix> live{{{}, 0, 0}};
    std::vector<const float *> logits{first};
    std::vector<Text> words;
    llama_batch batch = llama_batch_init(NEXT_BEAM, 0, 1);
    for (int len = 1; len <= NEXT_MAX; len++) {
        struct Option {
            size_t prefix;
            int token;
            float logProb;
        };
        std::vector<Option> options;
        for (size_t i = 0; i < live.size(); i++) {
            const float *l = logits[i];
            // A prefix either ends here (its word is a candidate) or goes on, if no word ends inside it.
            const float goOn = live[i].tokens.empty() ? 0 : logSigmoid(-l[mB]);
            if (!live[i].tokens.empty()) {
                std::string text;
                for (int t : live[i].tokens) text += mText[t];
                words.push_back({text, live[i].logProb + logEnd(l)});
            }
            const float norm = logNorm(l);
            std::vector<int> top;
            for (int t = 0; t < mVocabSize; t++)
                if (mHan[t]) top.push_back(t);
            const size_t k = std::min<size_t>(live[i].tokens.empty() ? NEXT_FIRST : 2, top.size());
            std::partial_sort(top.begin(), top.begin() + k, top.end(), [&](int a, int b) { return l[a] > l[b]; });
            for (size_t j = 0; j < k; j++) options.push_back({i, top[j], live[i].logProb + goOn + l[top[j]] - norm});
        }
        std::sort(options.begin(), options.end(), [](const Option &a, const Option &b) { return a.logProb > b.logProb; });
        if (options.size() > static_cast<size_t>(NEXT_BEAM)) options.resize(NEXT_BEAM);
        // Words can't get likelier than the prefixes they extend: stop once N words beat every prefix.
        std::stable_sort(words.begin(), words.end(), [](const Text &a, const Text &b) { return a.logProb > b.logProb; });
        if (options.empty() || (words.size() >= n && words[n - 1].logProb > options[0].logProb)) break;
        const int base = len % 2 ? 1 : NEXT_BEAM + 1;
        std::vector<Prefix> next;
        batch.n_tokens = 0;
        for (size_t j = 0; j < options.size(); j++) {
            const Prefix &parent = live[options[j].prefix];
            const int seq = base + static_cast<int>(j);
            llama_memory_seq_rm(mem, seq, -1, -1);
            llama_memory_seq_cp(mem, parent.seq, seq, -1, -1);
            next.push_back({parent.tokens, options[j].logProb, seq});
            next.back().tokens.push_back(options[j].token);
            const int k = batch.n_tokens++;
            batch.token[k] = options[j].token;
            batch.pos[k] = ctx.size() + parent.tokens.size();
            batch.n_seq_id[k] = 1;
            batch.seq_id[k][0] = seq;
            batch.logits[k] = true;
        }
        for (const Prefix &p : live)
            if (p.seq != 0) llama_memory_seq_rm(mem, p.seq, -1, -1);
        if (llama_decode(mCtx, batch) != 0) {
            llama_batch_free(batch);
            throw std::runtime_error("zh-lm: decoding failed");
        }
        live = std::move(next);
        logits.clear();
        for (size_t j = 0; j < live.size(); j++) logits.push_back(llama_get_logits_ith(mCtx, j));
    }
    llama_batch_free(batch);
    // The longest prefixes' own end, when the loop ran to NEXT_MAX.
    for (size_t i = 0; i < live.size(); i++)
        if (static_cast<int>(live[i].tokens.size()) == NEXT_MAX) {
            std::string text;
            for (int t : live[i].tokens) text += mText[t];
            words.push_back({text, live[i].logProb + logEnd(logits[i])});
        }
    std::stable_sort(words.begin(), words.end(), [](const Text &a, const Text &b) { return a.logProb > b.logProb; });
    if (words.size() > n) words.resize(n);
    return words;
}

}  // namespace zh_lm
