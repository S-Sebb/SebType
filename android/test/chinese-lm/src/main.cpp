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
// item's last key, every candidate the model scored to OUT.dump: item, Rime's rank (-1: the model's own, even
// when Rime has it too, so tune.py can try fewer of Rime's), the model's log probability, the text. profile=1 writes each key's time per step (zh_lm::Profile) to OUT.prof.
// core=1 runs the keyboard's own code instead (#264): core/'s Chinese engine, the model around Rime
// (src/chinese.cpp, withChineseModel), each key timed until the model's list for it has come; the weights
// are its own then, and of the options only threads counts.
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
    float plain = 0;          // of the plain-text log probability (zh_lm plain(), #502), for Rime's candidates
    float ownPlain = 0;       // the same for generated ones
    int plainTop = 3;         // the first candidates the plain-text term re-orders
    int pageSize = 6;      // what the keyboard reads after each key
    int dump = 0;
    int profile = 0;
    int threads = 1;       // the model's
    int core = 0;
    int fix = 0;           // Rime's corrections (sebtype_corr, #478) the model scores after the last key, dumped as -2
};

struct Scored {
    std::vector<std::string> rime;  // in Rime's order
    std::vector<float> logProb;
    std::vector<zh_lm::Text> generated;
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
    for (size_t i = 0; i < k; i++) prior.push_back(-opt.rankWeight * std::log1p(static_cast<float>(i)));
    if (pool.empty() && opt.generate == 0) return list;
    // Scoring first lets the beam reuse what it decoded.
    auto lp = model.score(context, typed, pool);
    std::vector<zh_lm::Text> generated;
    if (opt.generate > 0) generated = model.generate(context, typed, opt.generate, static_cast<int>(typed.size()));
    if (scored) *scored = {pool, lp, generated};
    for (const auto &g : generated)
        if (std::find(pool.begin(), pool.end(), g.text) == pool.end()) {
            pool.push_back(g.text);
            prior.push_back(-opt.rankWeight * std::log1p(opt.generatedRank));
            lp.push_back(g.logProb);
        }
    if (pool.empty()) return list;
    std::vector<size_t> order(pool.size());
    for (size_t i = 0; i < order.size(); i++) order[i] = i;
    const auto better = [&](size_t a, size_t b) { return lp[a] + prior[a] > lp[b] + prior[b]; };
    std::stable_sort(order.begin(), order.end(), better);
    if (opt.plain || opt.ownPlain) {  // as core/src/chinese.cpp's rank()
        const auto head = order.begin() + std::min<size_t>(order.size(), opt.plainTop);
        std::vector<std::string> best;
        for (auto i = order.begin(); i != head; ++i) best.push_back(pool[*i]);
        const auto p = model.plain(context, best);
        for (size_t j = 0; j < p.size(); j++) lp[order[j]] += (order[j] < k ? opt.plain : opt.ownPlain) * p[j];
        std::stable_sort(order.begin(), head, better);
    }
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
    for (int i = 6; i < argc; i++) {
        const auto kv = split(argv[i], '=');
        if (kv.size() != 2) return std::cerr << "bad option " << argv[i] << "\n", 2;
        const std::map<std::string, float *> floats{{"rankWeight", &opt.rankWeight}, {"generatedRank", &opt.generatedRank},
                                                {"plain", &opt.plain}, {"ownPlain", &opt.ownPlain}};
        const std::map<std::string, int *> ints{{"rerank", &opt.rerank}, {"generate", &opt.generate}, {"dump", &opt.dump},
                                              {"profile", &opt.profile}, {"threads", &opt.threads},
                                              {"core", &opt.core}, {"fix", &opt.fix},
                                              {"plainTop", &opt.plainTop}};
        if (floats.count(kv[0])) *floats.at(kv[0]) = std::stof(kv[1]);
        else if (ints.count(kv[0])) *ints.at(kv[0]) = std::stoi(kv[1]);
        else return std::cerr << "unknown option " << kv[0] << "\n", 2;
    }
    if (argc > 5 && !opt.core) model = std::make_unique<zh_lm::Model>(argv[5], opt.threads);

    sebtype::RimePaths paths{argv[1], argv[2], "", false, "rime_ice"};
    auto rime = sebtype::makeRime(paths);
    while (rime->busy()) std::this_thread::sleep_for(std::chrono::milliseconds(50));
    const bool core = argc > 5 && opt.core;
    if (core) {
        sebtype::ChineseModelPaths zh{argv[5], std::string(argv[1]) + "/opencc", opt.threads};
        zh.synchronous = true;
        zh.readings = std::string(argv[1]) + "/sebtype_readings.txt";
        rime = sebtype::withChineseModel(std::move(rime), zh, nullptr);
    }

    std::ifstream in(argv[3]);
    std::ofstream out(argv[4]), keysOut(std::string(argv[4]) + ".keys");
    std::ofstream dump;
    if (opt.dump) dump.open(std::string(argv[4]) + ".dump");
    std::ofstream prof;
    if (opt.profile && model) {
        prof.open(std::string(argv[4]) + ".prof");
        prof << "letters\trime";
        for (const char *name : zh_lm::Profile::names) prof << "\t" << name;
        prof << "\tdecodes\ttokens\n";
    }
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
        if (core) {
            // As the keyboard: the field's text before the cursor (untimed), then the keys, or for a next
            // word the text's last two characters typed in.
            std::string before = context;
            if (keys.empty())
                for (int n = 0; n < 2 && !before.empty(); n++) {
                    while ((static_cast<unsigned char>(before.back()) & 0xc0) == 0x80) before.pop_back();
                    before.pop_back();
                }
            rime->setContext(before, "", false);
            const auto t0 = clock::now();
            if (keys.empty()) rime->setContext(context, "", false);
            for (size_t i = 0; i < keys.size(); i++) {
                const auto k0 = clock::now();
                sebtype::Key k;
                k.sym = static_cast<unsigned char>(keys[i]);
                rime->key(k);
                list = texts(rime->candidates(opt.pageSize));
                keysOut << std::chrono::duration<double, std::micro>(clock::now() - k0).count() << "\n";
            }
            list = texts(rime->candidates(13));
            if (keys.empty()) keysOut << std::chrono::duration<double, std::micro>(clock::now() - t0).count() << "\n";
        }
        // The keyboard reads the text before the cursor when it changes, before any key: untimed, as in the
        // English harness. A next word is timed from the commit of the text's last two characters.
        if (model && !core) {
            std::string before = context;
            if (keys.empty())
                for (int n = 0; n < 2 && !before.empty(); n++) {
                    while ((static_cast<unsigned char>(before.back()) & 0xc0) == 0x80) before.pop_back();
                    before.pop_back();
                }
            model->prime(before);
        }
        if (keys.empty() && !core) {
            const auto t0 = clock::now();
            list = texts(rime->candidates(10));
            if (model)
                for (const auto &w : model->nextWords(context, 3)) list.push_back(w.text);
            keysOut << std::chrono::duration<double, std::micro>(clock::now() - t0).count() << "\n";
        }
        for (size_t i = 0; i < keys.size() && !core; i++) {
            const auto t0 = clock::now();
            sebtype::Key k;
            k.sym = static_cast<unsigned char>(keys[i]);
            rime->key(k);
            const bool last = i + 1 == keys.size();
            list = texts(rime->candidates(last ? 10 : std::max(opt.pageSize, model ? opt.rerank : 0)));
            const double rimeUs = std::chrono::duration<double, std::micro>(clock::now() - t0).count();
            if (model) model->profile = {};
            Scored scored;
            if (model) list = rerank(*model, opt, context, keys.substr(0, i + 1), list, last && opt.dump ? &scored : nullptr);
            for (size_t j = 0; j < scored.rime.size(); j++)
                dump << item << "\t" << j << "\t" << scored.logProb[j] << "\t" << scored.rime[j] << "\n";
            for (const auto &g : scored.generated) dump << item << "\t-1\t" << g.logProb << "\t" << g.text << "\n";
            if (model && last && opt.dump && opt.fix) {
                std::vector<std::string> fixes;
                for (const auto &c : rime->corrections(keys, opt.fix)) {
                    const auto cps = c.text;
                    bool hanOnly = !cps.empty();
                    for (size_t b = 0; b < cps.size();) {
                        const unsigned char u = cps[b];
                        hanOnly = hanOnly && u >= 0xe3 && u <= 0xe9;  // 3-byte UTF-8 in U+3000..U+9FFF
                        b += u < 0x80 ? 1 : (u >> 5) == 6 ? 2 : (u >> 4) == 14 ? 3 : 4;
                    }
                    if (hanOnly) fixes.push_back(c.text);
                }
                const auto lp = model->score(context, keys, fixes);
                for (size_t j = 0; j < fixes.size(); j++) dump << item << "\t-2\t" << lp[j] << "\t" << fixes[j] << "\n";
            }
            keysOut << std::chrono::duration<double, std::micro>(clock::now() - t0).count() << "\n";
            if (prof.is_open()) {
                prof << i + 1 << "\t" << rimeUs;
                for (double us : model->profile.us) prof << "\t" << us;
                prof << "\t" << model->profile.decodes << "\t" << model->profile.tokens << "\n";
            }
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
