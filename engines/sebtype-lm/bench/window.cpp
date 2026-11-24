// How the model's context window costs and predicts in long text (#359); bench.sh builds and runs it.
//
//   sebtype-lm-window MODEL time
//     Types the perf test's long-field words (android/perf/perf.sh) after an empty field and after its
//     20,000-character filler (the engine's last 1,000 characters of it, cut again at each space), a ranking
//     per letter and the next words after each space, as the keyboard's worker does, and prints the next words' and the rankings' times, median / p95.
//   sebtype-lm-window MODEL quality PARAGRAPHS
//     PARAGRAPHS: one paragraph a line. At every second word more than 300 characters into a paragraph, the
//     next word in the top 3 and first, for each window rule, and the tokens each next-words job decodes
//     when the paragraph is typed word by word (what the cache doesn't hold).
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <string>
#include <vector>

#include "llama.h"
#include "sebtype_lm.h"

namespace {

// A window: at most MAX characters of the line from a word's start. STEP > 0: its start stays where the last
// window started while that leaves MAX - STEP to MAX characters, then moves to MAX - STEP characters back
// (sebtype_lm.cpp's rule); 0 moves it with every word.
struct Rule {
    size_t max, step;
};

std::string window(const std::string &line, Rule r, std::string &last) {
    if (line.size() <= r.max) return last = line;
    if (r.step && !last.empty()) {
        const auto at = line.find(last, line.size() - r.max);
        if (at != std::string::npos && line.size() - at >= r.max - r.step && line[at - 1] == ' ')
            return last = line.substr(at);
    }
    const auto space = line.find(' ', line.size() - (r.max - r.step));
    return last = space == std::string::npos ? "" : line.substr(space + 1);
}

std::string lower(std::string s) {
    for (char &c : s) c = std::tolower(static_cast<unsigned char>(c));
    return s;
}

double ms(std::chrono::steady_clock::duration d) { return std::chrono::duration<double, std::milli>(d).count(); }

std::string stats(std::vector<double> v) {
    if (v.empty()) return "none";
    std::sort(v.begin(), v.end());
    char out[64];
    snprintf(out, sizeof out, "%.1f / %.1f ms (%zu)", v[v.size() / 2], v[std::min(v.size() - 1, v.size() * 95 / 100)],
             v.size());
    return out;
}

int time(sebtype_lm::Model &model) {
    const std::string typed = "the quick brown fox jumps over the lazy dog the quick brown fox jumps over the lazy dog ";
    std::string filler;
    while (filler.size() < 20000) filler += "The quick brown fox jumps over the lazy dog. ";
    for (const auto &[name, start] : {std::pair<std::string, std::string>{"short", ""}, {"long", filler}}) {
        std::vector<double> next, rank;
        std::string context = start, word;
        model.nextWords(context, 5);  // the field opens
        for (char c : typed) {
            if (c != ' ') {
                word += c;
                const auto t = std::chrono::steady_clock::now();
                model.score(context, word, {word, word + "s", word + "e", word.substr(1)}, true);
                rank.push_back(ms(std::chrono::steady_clock::now() - t));
                continue;
            }
            context += word + " ";
            word.clear();
            // The engine keeps the field's last 1,000 characters and cuts them again whenever it reads the
            // field: the worst case, a read at every space.
            if (context.size() > 1000) context.erase(0, context.size() - 1000);
            const auto t = std::chrono::steady_clock::now();
            model.nextWords(context, 5);
            next.push_back(ms(std::chrono::steady_clock::now() - t));
        }
        printf("%s field: next words %s, rankings %s\n", name.c_str(), stats(next).c_str(), stats(rank).c_str());
    }
    return 0;
}

int quality(sebtype_lm::Model &model, const std::string &modelPath, const std::string &paragraphs) {
    llama_model *vocabModel = [&] {
        auto p = llama_model_default_params();
        p.vocab_only = true;
        return llama_model_load_from_file(modelPath.c_str(), p);
    }();
    const llama_vocab *vocab = llama_model_get_vocab(vocabModel);
    auto tokens = [&](const std::string &text) {
        std::vector<llama_token> out(text.size() + 2);
        out.resize(std::max(0, llama_tokenize(vocab, text.data(), text.size(), out.data(), out.size(), true, false)));
        return out;
    };
    std::vector<std::string> lines;
    std::ifstream in(paragraphs);
    for (std::string line; std::getline(in, line);)
        if (line.size() > 320) lines.push_back(line);

    const std::vector<Rule> rules = {{300, 0}, {200, 0}, {150, 0}, {100, 0}, {300, 100}, {300, 150}, {300, 200}, {250, 100}};
    for (Rule r : rules) {
        int n = 0, top1 = 0, top3 = 0, every = 0;
        double decoded = 0, jobs = 0, longest = 0;
        for (const std::string &line : lines) {
            std::vector<llama_token> cached;
            std::string last;
            for (size_t i = 1; i < line.size(); i++) {
                if (line[i - 1] != ' ' || line[i] == ' ') continue;
                const std::string win = window(line.substr(0, i - 1), r, last);
                const auto t = tokens(win);
                size_t keep = 0;
                while (keep < t.size() && keep < cached.size() && t[keep] == cached[keep]) keep++;
                decoded += t.size() - std::min(keep, t.size() - 1);
                jobs++;
                cached = t;
                if (i < 300) continue;
                longest = std::max(longest, double(t.size()));
                size_t end = i;
                while (end < line.size() && (std::isalpha(static_cast<unsigned char>(line[end])) || line[end] == '\''))
                    end++;
                if (end == i || !std::isalpha(static_cast<unsigned char>(line[i])) || every++ % 2) continue;
                const std::string target = lower(line.substr(i, end - i));
                const auto words = model.nextWords(win, 3);
                n++;
                for (size_t k = 0; k < words.size(); k++)
                    if (lower(words[k].word) == target) (k == 0 ? top1 : top3)++, k = words.size();
            }
        }
        printf("window %zu step %zu: next word first %.1f %%, top 3 %.1f %% (%d words); tokens decoded per job %.1f, "
               "window at most %.0f tokens\n",
               r.max, r.step, 100.0 * top1 / n, 100.0 * (top1 + top3) / n, n, decoded / jobs, longest);
    }
    llama_model_free(vocabModel);
    return 0;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 3) return fprintf(stderr, "usage: %s MODEL time | MODEL quality PARAGRAPHS\n", argv[0]), 2;
    sebtype_lm::Model model(argv[1], 1);
    const std::string mode = argv[2];
    if (mode == "time") return time(model);
    if (mode == "quality" && argc == 4) return quality(model, argv[1], argv[3]);
    return fprintf(stderr, "usage: %s MODEL time | MODEL quality PARAGRAPHS\n", argv[0]), 2;
}
