// sebtype-zh-keys: the Chinese model's jobs as core/src/chinese.cpp runs them while android/perf/perf.sh's 中 set
// is typed, timed one by one (#264). Built for the phone by zh-keys.sh, to run under taskset on its big or
// little cores. Each letter: score() of 4 candidates, generate() with a beam of 2 and plain() of 3; each space commits the
// first and asks nextWords(), as does the empty field before the first key. Rime isn't here: a second copy of
// the model stands in for it, its own beam of 4 for the letters (untimed), so the scored texts are likely ones
// of the right length, as Rime's first 4 are. MIT, SebType.
//
//   sebtype-zh-keys MODEL THREADS [ROUNDS [GAP_MS]]
//
// Prints a line per job (kind, letters, ms, decodes, tokens) and then, per kind, p50 / p95 over ROUNDS rounds.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <vector>

#include "ggml-backend.h"
#include "zh_lm.h"

int main(int argc, char **argv) {
    if (argc < 3) return std::fprintf(stderr, "usage: sebtype-zh-keys MODEL THREADS [ROUNDS [GAP_MS]]\n"), 2;
    const int threads = std::atoi(argv[2]), rounds = argc > 3 ? std::atoi(argv[3]) : 3;
    const auto gap = std::chrono::milliseconds(argc > 4 ? std::atoi(argv[4]) : 0);  // between keys, as perf.sh's 700
    // A build with llama.cpp's CPU code in variants (the phone's): the best one next to the binary.
    const std::string self = argv[0];
    ggml_backend_load_all_from_path(self.find('/') == std::string::npos ? "." : self.substr(0, self.rfind('/')).c_str());
    std::fprintf(stderr, "CPU:");
    ggml_backend_reg_t cpu = ggml_backend_reg_by_name("CPU");
    if (auto features = reinterpret_cast<ggml_backend_get_features_t>(ggml_backend_reg_get_proc_address(cpu, "ggml_backend_get_features")))
        for (auto *f = features(cpu); f->name; f++) std::fprintf(stderr, " %s=%s", f->name, f->value);
    std::fprintf(stderr, "\n");
    zh_lm::Model model(argv[1], threads), rime(argv[1], 1);
    const std::string typed = "nihao women jintiantianqihenhao ranhou zhongguo ";
    std::vector<double> rank, next;
    using clock = std::chrono::steady_clock;
    auto ms = [](clock::time_point t0) { return std::chrono::duration<double, std::milli>(clock::now() - t0).count(); };
    auto line = [&](const char *kind, const std::string &letters, double t) {
        std::printf("%s\t%s\t%.2f\t%d\t%d\n", kind, letters.c_str(), t, model.profile.decodes, model.profile.tokens);
    };
    for (int r = 0; r < rounds; r++) {
        std::string context, letters;
        model.profile = {};
        auto t0 = clock::now();
        model.nextWords(context, 5);
        next.push_back(ms(t0));
        line("next", "", next.back());
        for (char c : typed) {
            std::this_thread::sleep_for(gap);
            if (c == ' ') {
                const auto first = rime.generate(context, letters, 1, static_cast<int>(letters.size()));
                if (!first.empty()) context += first[0].text;
                letters.clear();
                model.profile = {};
                t0 = clock::now();
                model.nextWords(context, 5);
                next.push_back(ms(t0));
                line("next", "", next.back());
                continue;
            }
            letters += c;
            std::vector<std::string> texts;
            for (const auto &t : rime.generate(context, letters, 4, static_cast<int>(letters.size()))) texts.push_back(t.text);
            model.profile = {};
            t0 = clock::now();
            model.score(context, letters, texts);
            const auto own = model.generate(context, letters, 2, static_cast<int>(letters.size()));
            // The first 3 again as plain text (#502): the model's own first, then Rime's.
            std::vector<std::string> best;
            for (const auto &g : own) best.push_back(g.text);
            for (const auto &t : texts) best.push_back(t);
            best.resize(std::min<size_t>(best.size(), 3));
            model.plain(context, best);
            rank.push_back(ms(t0));
            line("rank", letters, rank.back());
        }
    }
    auto pct = [](std::vector<double> v, double p) {
        std::sort(v.begin(), v.end());
        return v[std::min(v.size() - 1, static_cast<size_t>(p * (v.size() - 1) + 0.5))];
    };
    std::printf("# threads %d: rank %.1f / %.1f ms (%zu), next %.1f / %.1f ms (%zu)\n", threads, pct(rank, .5),
                pct(rank, .95), rank.size(), pct(next, .5), pct(next, .95), next.size());
}
