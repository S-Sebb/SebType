// SebType's Chinese model on llama.cpp's public API (llama.h). The model's text format is tools/chinese-lm's
// (pack.py): <s> text, and a pinyin example "<T>typed letters<S>text<E>" in front of the text it types.
// core/src/chinese.cpp runs it around Rime (#264); the Chinese harness (android/test/chinese-lm) measures it.
// MIT, SebType.
#include "zh_lm.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <map>
#include <mutex>
#include <optional>
#include <stdexcept>

#include "ggml-backend.h"
#include "ggml-cpu.h"
#include "llama.h"

namespace zh_lm {
namespace {

constexpr size_t CONTEXT_CHARS = 64;  // the field's text before the cursor the model reads, at most, and its tokens
// The cache's cells, shared by every sequence: the example (at most 64 context tokens and MAX_LETTERS), the
// candidates' tree and the beam's steps take well under 512. Each decode takes at most 256 tokens, which also
// sizes llama.cpp's logits and compute buffers (#264: 1,024 cells and 512 tokens cost some 20 MB more).
constexpr int CELLS = 512, BATCH = 256;
// The candidates' tree, at most: with the example and the beam's steps (2 · width · MAX_LETTERS at most) it
// stays within CELLS. A text that doesn't fit is left out, and scores -inf.
constexpr size_t TREE_MAX = 240;
constexpr int MAX_BRANCHES = 48;  // score()'s texts and twice generate()'s width, at most
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

// Adds the time until it goes out of scope to SLOT.
struct Timer {
    Timer(double &slot) : slot(slot) {}  // GCC 15 in C++17 can't emplace an aggregate
    double &slot;
    std::chrono::steady_clock::time_point start = std::chrono::steady_clock::now();
    ~Timer() { slot += std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count(); }
};

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
    mp.progress_callback = [](float, void *) { return true; };  // no dots on stderr
    mModel = llama_model_load_from_file(path.c_str(), mp);
    if (!mModel) throw std::runtime_error("zh-lm: can't load " + path);
    auto cp = llama_context_default_params();
    cp.n_ctx = CELLS;
    cp.n_batch = cp.n_ubatch = BATCH;
    cp.n_seq_max = MAX_BRANCHES + 1;
    cp.n_threads = cp.n_threads_batch = threads;
    cp.kv_unified = true;
    cp.no_perf = true;
    mCtx = llama_init_from_model(mModel, cp);
    if (!mCtx) throw std::runtime_error("zh-lm: can't make a context for " + path);
    // Threads that last as long as the model: without them llama.cpp starts and ends THREADS - 1 threads for
    // every decode, which the phone started on its little cores, where the rest of each step waited for them
    // (#264). From the CPU backend, which may be a library loaded at run time (the phone's).
    if (threads > 1) {
        ggml_backend_reg_t cpu = ggml_backend_reg_by_name("CPU");
        auto make = reinterpret_cast<decltype(&ggml_threadpool_new)>(ggml_backend_reg_get_proc_address(cpu, "ggml_threadpool_new"));
        mFreePool = reinterpret_cast<void (*)(ggml_threadpool *)>(ggml_backend_reg_get_proc_address(cpu, "ggml_threadpool_free"));
        auto params = ggml_threadpool_params_default(threads);
        mPool = make && mFreePool ? make(&params) : nullptr;
        if (mPool) llama_attach_threadpool(mCtx, mPool, nullptr);
    }
    mVocab = llama_model_get_vocab(mModel);
    mVocabSize = llama_vocab_n_tokens(mVocab);
    mBos = llama_vocab_bos(mVocab);

    std::vector<bool> han1(mVocabSize);
    mText.resize(mVocabSize);
    for (int t = 0; t < mVocabSize; t++) {
        const std::string raw = llama_vocab_get_text(mVocab, t);
        mPiece.emplace(raw, t);
        char buf[64];
        const int n = llama_token_to_piece(mVocab, t, buf, sizeof buf, 0, true);
        mText[t] = n > 0 ? std::string(buf, n) : "";
        const bool control = llama_vocab_is_control(mVocab, t) || llama_vocab_is_eog(mVocab, t);
        han1[t] = !control && han(codepoint(mText[t])) && mText[t].size() == 3;
    }
    auto id = [&](const std::string &s) {
        auto it = mPiece.find(s);
        if (it == mPiece.end()) throw std::runtime_error("zh-lm: no piece " + s + ": not SebType's Chinese model");
        return it->second;
    };
    mT = id("<T>"), mS = id("<S>"), mE = id("<E>"), mB = id("<B>");
    for (char c = 'a'; c <= 'z'; c++) mLetter.push_back(id(std::string(1, c)));
    for (int t = 0; t < mVocabSize; t++)
        if (han1[t]) mHan.push_back(t);
}

Model::~Model() {
    if (mCtx) llama_free(mCtx);
    if (mPool) mFreePool(mPool);
    if (mModel) llama_model_free(mModel);
}

// As training does it (tools/chinese-lm/pack.py): a piece per character, or its bytes'. Not llama_tokenize(),
// which starts every text with a "▁" the model never saw: the GGUF says add_space_prefix, as llama.cpp's
// converter writes for every SentencePiece model, though this one has add_dummy_prefix off.
std::vector<int> Model::tokenize(const std::string &text) const {
    std::vector<int> out;
    for (size_t i = 0; i < text.size();) {
        const unsigned char c = text[i];
        const size_t n = c < 0x80 ? 1 : (c >> 5) == 6 ? 2 : (c >> 4) == 14 ? 3 : (c >> 3) == 30 ? 4 : 1;
        const std::string ch = text.substr(i, n);
        i += n;
        if (auto it = mPiece.find(ch == " " ? "\u2581" : ch); it != mPiece.end()) {
            out.push_back(it->second);
            continue;
        }
        for (unsigned char b : ch) {
            char hex[8];
            snprintf(hex, sizeof hex, "<0x%02X>", b);
            out.push_back(mPiece.at(hex));
        }
    }
    return out;
}

std::vector<int> Model::contextTokens(const std::string &context) const {
    const auto nl = context.rfind('\n');
    std::vector<int> out{mBos};
    const auto text = tokenize(lastChars(nl == std::string::npos ? context : context.substr(nl + 1), CONTEXT_CHARS));
    // Characters outside the vocabulary take a token per byte: the positions stay within the model's 256.
    out.insert(out.end(), text.end() - std::min(text.size(), CONTEXT_CHARS), text.end());
    return out;
}

std::vector<int> Model::examplePrefix(const std::string &context, const std::string &typed) const {
    std::vector<int> prefix = contextTokens(context);
    prefix.push_back(mT);
    for (char c : typed.substr(0, MAX_LETTERS))
        if (c >= 'a' && c <= 'z') prefix.push_back(mLetter[c - 'a']);
    prefix.push_back(mS);
    return prefix;
}

void Model::clearBranches() {
    llama_memory_t mem = llama_get_memory(mCtx);
    for (int s = 1; s <= mBranches; s++) llama_memory_seq_rm(mem, s, -1, -1);
    mBranches = 0;
    mExample.clear();
    mNodes.clear();
}

const float *Model::advance(const std::vector<int> &prefix) {
    Timer timer{profile.us[Profile::Advance]};
    clearBranches();
    llama_memory_t mem = llama_get_memory(mCtx);
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
        profile.decodes++, profile.tokens += batch.n_tokens;
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

void Model::decodeExample(const std::vector<int> &prefix, const std::vector<std::vector<int>> &followers) {
    std::optional<Timer> timer{{profile.us[Profile::BranchCache]}};
    // The tree: a token for each distinct start of a follower, on the sequence of every follower through it.
    std::map<std::vector<int>, size_t> at;
    std::vector<std::vector<int>> paths, seqs;
    int nSeqs = 0;
    for (const auto &f : followers) {
        if (f.empty()) continue;
        size_t added = 0;
        for (size_t n = 1; n <= f.size(); n++) added += !at.count({f.begin(), f.begin() + n});
        if (paths.size() + added > TREE_MAX) continue;
        if (++nSeqs > MAX_BRANCHES) throw std::runtime_error("zh-lm: too many branches");
        std::vector<int> path;
        for (int t : f) {
            path.push_back(t);
            auto [it, added] = at.emplace(path, paths.size());
            if (added) paths.push_back(path), seqs.emplace_back();
            seqs[it->second].push_back(nSeqs);
        }
    }
    // The example's tokens the cache doesn't hold go first, on every sequence, then the tree, each node after
    // its parent, in batches of at most n_batch: a node in a later batch reads its parent from the cache.
    size_t keep = 0;
    while (keep < mCached.size() && keep < prefix.size() && mCached[keep] == prefix[keep]) keep++;
    keep = std::min(keep, prefix.size() - 1);  // the last token is decoded again for its logits
    clearBranches();
    llama_memory_t mem = llama_get_memory(mCtx);
    llama_memory_seq_rm(mem, 0, keep, -1);
    for (int s = 1; s <= nSeqs; s++) llama_memory_seq_cp(mem, 0, s, -1, -1);
    mBranches = nSeqs;
    const size_t tail = prefix.size() - keep, total = tail + paths.size();
    const size_t nBatch = llama_n_batch(mCtx);
    llama_batch batch = llama_batch_init(std::min(total, nBatch), 0, nSeqs + 1);
    auto node = [&](const float *l, int seq) { return Node{seq, logNorm(l), std::vector<float>(l, l + mVocabSize)}; };
    for (size_t first = 0; first < total; first += nBatch) {
        const size_t last = std::min(total, first + nBatch);
        batch.n_tokens = 0;
        for (size_t i = first; i < last; i++) {
            const int k = batch.n_tokens++;
            if (i < tail) {
                batch.token[k] = prefix[keep + i];
                batch.pos[k] = keep + i;
                batch.n_seq_id[k] = nSeqs + 1;
                for (int s = 0; s <= nSeqs; s++) batch.seq_id[k][s] = s;
                batch.logits[k] = i + 1 == tail;
            } else {
                const auto &path = paths[i - tail];
                const auto &on = seqs[i - tail];
                batch.token[k] = path.back();
                batch.pos[k] = prefix.size() + path.size() - 1;
                batch.n_seq_id[k] = on.size();
                for (size_t s = 0; s < on.size(); s++) batch.seq_id[k][s] = on[s];
                batch.logits[k] = true;
            }
        }
        timer.emplace(profile.us[Profile::BranchDecode]);
        profile.decodes++, profile.tokens += batch.n_tokens;
        if (llama_decode(mCtx, batch) != 0) {
            llama_batch_free(batch);
            mCached.clear();
            llama_memory_seq_rm(mem, 0, -1, -1);
            throw std::runtime_error("zh-lm: decoding failed");
        }
        // The next decode overwrites the logits.
        timer.emplace(profile.us[Profile::ScoreNorm]);
        for (size_t i = std::max(first, tail - 1); i < last; i++) {
            const float *l = llama_get_logits_ith(mCtx, i - first);
            if (i < tail) mNodes.emplace(std::vector<int>{}, node(l, 0));
            else mNodes.emplace(paths[i - tail], node(l, seqs[i - tail][0]));
        }
    }
    llama_batch_free(batch);
    mCached = mExample = prefix;
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
    std::optional<Timer> timer{{profile.us[Profile::Prefix]}};
    const auto prefix = examplePrefix(context, typed);
    std::vector<std::vector<int>> pieces, followers;
    for (const auto &text : texts) {
        pieces.push_back(tokenize(text));
        followers.push_back(pieces.back());
        pieces.back().push_back(mE);
    }
    // The last key's own candidates go in the batch too, unscored: the beam often follows them again, and a
    // token in this batch costs about half of one in a step of its own.
    for (const auto &g : mGuesses)
        if (std::find(followers.begin(), followers.end(), g) == followers.end()) followers.push_back(g);
    timer.reset();
    decodeExample(prefix, followers);
    Timer norms{profile.us[Profile::ScoreNorm]};
    std::vector<float> out;
    for (const auto &p : pieces) {
        std::vector<int> path;
        out.push_back(0);
        for (size_t j = 0; j < p.size(); j++) {
            const auto n = mNodes.find(path);
            if (n == mNodes.end()) {  // left out of the tree
                out.back() = -INFINITY;
                break;
            }
            out.back() += n->second.logits[p[j]] - n->second.norm;
            path.push_back(p[j]);
        }
    }
    return out;
}

void Model::prime(const std::string &context) {
    mGuesses.clear();
    advance(contextTokens(context));
}

std::vector<Text> Model::generate(const std::string &context, const std::string &typed, int width, int maxChars) {
    // Each beam lives on a sequence of its own in the cache: a step copies its parent's (cells are shared) and
    // decodes one token, so a step costs a token per beam, but none for a beam that follows a text score()
    // decoded (mNodes). Steps use the sequences after score()'s, WIDTH of them, and the WIDTH after those, in
    // turn.
    struct Beam {
        std::vector<int> tokens;
        float logProb;
        int seq;
        const float *logits;
        float norm;
    };
    std::optional<Timer> timer{{profile.us[Profile::Prefix]}};
    const auto prefix = examplePrefix(context, typed);
    timer.reset();
    if (prefix != mExample) decodeExample(prefix, {});
    const int first = mBranches + 1;
    if (mBranches + 2 * width > MAX_BRANCHES) throw std::runtime_error("zh-lm: too many branches");
    mBranches += 2 * width;  // the next decode clears them
    llama_memory_t mem = llama_get_memory(mCtx);
    const Node &root = mNodes.at({});
    std::vector<Beam> beams{{{}, 0, 0, root.logits.data(), root.norm}};
    struct Done {
        std::vector<int> tokens;
        float logProb;
    };
    std::vector<Done> done;
    llama_batch batch = llama_batch_init(width, 0, 1);
    for (int step = 0; step <= maxChars && !beams.empty(); step++) {
        if (stale && stale()) {  // typed on: the result would go unread
            llama_batch_free(batch);
            mGuesses.clear();
            return {};
        }
        struct Option {
            size_t beam;
            int token;
            float logProb;
        };
        timer.emplace(profile.us[Profile::BeamNorm]);
        std::vector<Option> options;
        for (size_t i = 0; i < beams.size(); i++) {
            const float *l = beams[i].logits;
            const float norm = std::isnan(beams[i].norm) ? logNorm(l) : beams[i].norm;
            // Every beam's own end is a candidate, however its Han continuations rank against <E>.
            if (!beams[i].tokens.empty()) done.push_back({beams[i].tokens, beams[i].logProb + l[mE] - norm});
            if (step == maxChars) continue;
            std::vector<int> top = mHan;
            const size_t k = std::min<size_t>(width, top.size());
            std::partial_sort(top.begin(), top.begin() + k, top.end(), [&](int a, int b) { return l[a] > l[b]; });
            for (size_t j = 0; j < k; j++) options.push_back({i, top[j], beams[i].logProb + l[top[j]] - norm});
        }
        std::sort(options.begin(), options.end(), [](const Option &a, const Option &b) { return a.logProb > b.logProb; });
        if (options.size() > static_cast<size_t>(width)) options.resize(width);
        std::sort(done.begin(), done.end(), [](const Done &a, const Done &b) { return a.logProb > b.logProb; });
        // Extending a beam only lowers its probability: stop once WIDTH finished ones beat every beam left.
        if (options.empty() || (static_cast<int>(done.size()) >= width && done[width - 1].logProb > options[0].logProb)) break;
        timer.emplace(profile.us[Profile::BeamCache]);
        const int base = step % 2 ? first + width : first;
        std::vector<Beam> next;
        std::vector<size_t> decoded;  // the beams of NEXT the batch decodes
        batch.n_tokens = 0;
        for (size_t j = 0; j < options.size(); j++) {
            const Beam &parent = beams[options[j].beam];
            std::vector<int> tokens = parent.tokens;
            tokens.push_back(options[j].token);
            if (auto it = mNodes.find(tokens); it != mNodes.end()) {
                next.push_back({tokens, options[j].logProb, it->second.seq, it->second.logits.data(), it->second.norm});
                continue;
            }
            // The parent's sequence may hold a text score() decoded past the parent: the copy leaves it out.
            const int seq = base + static_cast<int>(j);
            const int pos = prefix.size() + parent.tokens.size();
            llama_memory_seq_rm(mem, seq, -1, -1);
            llama_memory_seq_cp(mem, parent.seq, seq, -1, -1);
            llama_memory_seq_rm(mem, seq, pos, -1);
            next.push_back({tokens, options[j].logProb, seq, nullptr, NAN});
            decoded.push_back(next.size() - 1);
            const int k = batch.n_tokens++;
            batch.token[k] = options[j].token;
            batch.pos[k] = pos;
            batch.n_seq_id[k] = 1;
            batch.seq_id[k][0] = seq;
            batch.logits[k] = true;
        }
        for (const Beam &b : beams)
            if (b.seq >= first) llama_memory_seq_rm(mem, b.seq, -1, -1);
        if (batch.n_tokens > 0) {
            timer.emplace(profile.us[Profile::BeamDecode]);
            profile.decodes++, profile.tokens += batch.n_tokens;
            if (llama_decode(mCtx, batch) != 0) {
                llama_batch_free(batch);
                throw std::runtime_error("zh-lm: decoding failed");
            }
            for (size_t j = 0; j < decoded.size(); j++) next[decoded[j]].logits = llama_get_logits_ith(mCtx, j);
        }
        beams = std::move(next);
    }
    timer.reset();
    llama_batch_free(batch);
    if (done.size() > static_cast<size_t>(width)) done.resize(width);
    std::vector<Text> out;
    mGuesses.clear();
    for (const Done &d : done) {
        std::string text;
        for (int t : d.tokens) text += mText[t];
        out.push_back({text, d.logProb});
        mGuesses.push_back(d.tokens);
    }
    return out;
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
    // An empty field's are always the same, and asked for as it opens, while the phone is busiest (#264).
    const bool empty = ctx.size() == 1;
    if (empty && mEmptyWords.first == n) return mEmptyWords.second;
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
            std::vector<int> top = mHan;
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
    if (empty) mEmptyWords = {n, words};
    return words;
}

}  // namespace zh_lm
