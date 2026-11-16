// The Chinese harness (#259): types each item of a set into today's 中文, core/'s Rime engine (src/rime.cpp) on
// SebType's data, one key at a time as a keyboard does, reading the candidates after every key, and with a
// model (tools/chinese-lm) re-ranks them on every key and, with nothing typed, predicts the next words.
// MIT, SebType.
//
//   zhbench SHARED USER SET OUT [MODEL.gguf [NAME=VALUE...]]
//
// SET: lines of context<TAB>keys<TAB>target<TAB>note (make_sets.py). OUT gets a line per item:
// rank<TAB>keys<TAB>target<TAB>first three candidates joined by |, rank being the target's place in the list
// (0 first, -1 not in the first 10). OUT.keys gets each key's time in microseconds: the key, the candidates
// read and, with a model, its work. Its last line is the process's peak RSS in kB.
// NAME=VALUE sets a ranking weight (Options below), tuned on the dev sets (tune.py); dump=1 writes, after each
// item's last key, every candidate the model scored to OUT.dump: item, Rime's rank (-1: the model's own), the
// model's log probability, the text.
#include <sebtype/hosts.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <iostream>
#include <map>
#include <memory>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "zh_lm.h"

namespace {

struct Options {
    int rerank = 4;        // Rime's first candidates the model scores
    float rankWeight = 1;  // of -log(1 + Rime's rank): how much Rime's order counts against the model's
    int generate = 0;      // the model's own candidates (beam width), 0 for none
    float generatedRank = 8;  // the Rime rank a generated candidate counts as
    int pageSize = 6;      // what the keyboard reads after each key
    int dump = 0;
};

struct Scored {
    std::vector<std::string> pool;
    std::vector<int> rimeRank;  // -1: the model's own
    std::vector<float> logProb;
};

std::vector<std::string> split(const std::string &s, char sep) {
    std::vector<std::string> out;
    std::stringstream in(s);
    std::string part;
    while (std::getline(in, part, sep)) out.push_back(part);
    if (!s.empty() && s.back() == sep) out.emplace_back();
    return out;
}

std::vector<std::string> texts(const std::vector<sebtype::Candidate> &list) {
    std::vector<std::string> out;
    for (const auto &c : list) out.push_back(c.text);
    return out;
}

// Rime's candidates with the model's order over the first opt.rerank (and its own candidates among them).
std::vector<std::string> rerank(zh_lm::Model &model, const Options &opt, const std::string &context,
                                const std::string &typed, std::vector<std::string> list, Scored *scored = nullptr) {
    const size_t k = std::min<size_t>(opt.rerank, list.size());
    std::vector<std::string> pool(list.begin(), list.begin() + k);
    std::vector<float> prior;
    std::vector<int> ranks;
    for (size_t i = 0; i < k; i++) {
        prior.push_back(-opt.rankWeight * std::log1p(static_cast<float>(i)));
        ranks.push_back(static_cast<int>(i));
    }
    if (opt.generate > 0) {
        for (const auto &g : model.generate(context, typed, opt.generate, static_cast<int>(typed.size())))
            if (std::find(pool.begin(), pool.end(), g.text) == pool.end()) {
                pool.push_back(g.text);
                prior.push_back(-opt.rankWeight * std::log1p(opt.generatedRank));
                ranks.push_back(-1);
            }
    }
    if (pool.empty()) return list;
    const auto lp = model.score(context, typed, pool);
    if (scored) *scored = {pool, ranks, lp};
    std::vector<size_t> order(pool.size());
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    std::stable_sort(order.begin(), order.end(), [&](size_t a, size_t b) { return lp[a] + prior[a] > lp[b] + prior[b]; });
    std::vector<std::string> out;
    for (size_t i : order) out.push_back(pool[i]);
    for (size_t i = k; i < list.size(); i++)
        if (std::find(out.begin(), out.end(), list[i]) == out.end()) out.push_back(list[i]);
    return out;
}

long peakRssKb() {
    std::ifstream st("/proc/self/status");
    std::string line;
    while (std::getline(st, line))
        if (line.rfind("VmHWM:", 0) == 0) return std::stol(line.substr(6));
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 5) {
        std::cerr << "usage: zhbench SHARED USER SET OUT [MODEL.gguf [NAME=VALUE...]]\n";
        return 2;
    }
    Options opt;
    std::unique_ptr<zh_lm::Model> model;
    if (argc > 5) model = std::make_unique<zh_lm::Model>(argv[5], 1);
    for (int i = 6; i < argc; i++) {
        const auto kv = split(argv[i], '=');
        if (kv.size() != 2) return std::cerr << "bad option " << argv[i] << "\n", 2;
        const std::map<std::string, float *> floats{{"rankWeight", &opt.rankWeight}, {"generatedRank", &opt.generatedRank}};
        const std::map<std::string, int *> ints{{"rerank", &opt.rerank}, {"generate", &opt.generate}, {"dump", &opt.dump}};
        if (floats.count(kv[0])) *floats.at(kv[0]) = std::stof(kv[1]);
        else if (ints.count(kv[0])) *ints.at(kv[0]) = std::stoi(kv[1]);
        else return std::cerr << "unknown option " << kv[0] << "\n", 2;
    }

    sebtype::RimePaths paths{argv[1], argv[2], "", false, "rime_ice"};
    auto rime = sebtype::makeRime(paths);
    while (rime->busy()) std::this_thread::sleep_for(std::chrono::milliseconds(50));

    std::ifstream in(argv[3]);
    std::ofstream out(argv[4]), keysOut(std::string(argv[4]) + ".keys");
    std::ofstream dump;
    if (opt.dump) dump.open(std::string(argv[4]) + ".dump");
    int item = -1;
    std::string line;
    using clock = std::chrono::steady_clock;
    while (std::getline(in, line)) {
        const auto f = split(line, '\t');
        if (f.size() < 3) continue;
        const std::string &context = f[0], &keys = f[1], &target = f[2];
        item++;
        rime->clear();
        std::vector<std::string> list;
        // The keyboard reads the text before the cursor when it changes, before any key: untimed, as in the
        // English harness. A next word is timed from the commit of the text's last two characters.
        if (model) {
            std::string before = context;
            if (keys.empty())
                for (int n = 0; n < 2 && !before.empty(); n++) {
                    while ((static_cast<unsigned char>(before.back()) & 0xc0) == 0x80) before.pop_back();
                    before.pop_back();
                }
            model->prime(before);
        }
        if (keys.empty()) {
            const auto t0 = clock::now();
            list = texts(rime->candidates(10));
            if (model)
                for (const auto &w : model->nextWords(context, 3)) list.push_back(w.text);
            keysOut << std::chrono::duration<double, std::micro>(clock::now() - t0).count() << "\n";
        }
        for (size_t i = 0; i < keys.size(); i++) {
            const auto t0 = clock::now();
            sebtype::Key k;
            k.sym = static_cast<unsigned char>(keys[i]);
            rime->key(k);
            const bool last = i + 1 == keys.size();
            list = texts(rime->candidates(last ? 10 : std::max(opt.pageSize, model ? opt.rerank : 0)));
            Scored scored;
            if (model) list = rerank(*model, opt, context, keys.substr(0, i + 1), list, last && opt.dump ? &scored : nullptr);
            for (size_t j = 0; j < scored.pool.size(); j++)
                dump << item << "\t" << scored.rimeRank[j] << "\t" << scored.logProb[j] << "\t" << scored.pool[j] << "\n";
            keysOut << std::chrono::duration<double, std::micro>(clock::now() - t0).count() << "\n";
        }
        int rank = -1;
        for (size_t i = 0; i < list.size() && i < 10 && rank < 0; i++)
            if (list[i] == target) rank = static_cast<int>(i);
        std::string top;
        for (size_t i = 0; i < list.size() && i < 3; i++) top += (i ? "|" : "") + list[i];
        out << rank << "\t" << keys << "\t" << target << "\t" << top << "\n";
    }
    keysOut << "rss_kb " << peakRssKb() << "\n";
    return 0;
}
