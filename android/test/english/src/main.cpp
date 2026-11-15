// english-harness SET.tsv OUT.tsv STACK_ARG...: types each item of a test set (make_sets.py) into one stack,
// letter by letter as the keyboard asks for suggestions on every key, and writes for each item what a space
// commits, the top 3 of the strip, the time each key took, and after how many keys the word was first among
// the top 3 (0: never).
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <fstream>
#include <iostream>
#include <sstream>

#include "harness.h"

namespace {

std::vector<std::string> split(const std::string &s, char sep) {
    std::vector<std::string> out;
    std::string field;
    std::istringstream in(s);
    while (std::getline(in, field, sep)) out.push_back(field);
    if (!s.empty() && s.back() == sep) out.push_back("");
    return out;
}

std::vector<int> numbers(const std::string &s) {
    std::vector<int> out;
    for (const std::string &n : split(s, ',')) out.push_back(std::stoi(n));
    return out;
}

}  // namespace

int main(int argc, char **argv) {
    if (argc < 4) {
        std::cerr << "usage: english-harness SET.tsv OUT.tsv STACK_ARG...\n";
        return 2;
    }
    std::ifstream in(argv[1]);
    std::ofstream out(argv[2]);
    if (!in || !out) {
        std::cerr << "english-harness: can't open " << argv[1] << " or " << argv[2] << "\n";
        return 1;
    }
    auto stack = harness::makeStack(std::vector<std::string>(argv + 3, argv + argc));

    std::string line;
    while (std::getline(in, line)) {
        const auto f = split(line, '\t');
        harness::Item item{f.at(0), f.at(1), f.at(2), {}, {}};
        if (!item.typed.empty()) item.xs = numbers(f.at(3)), item.ys = numbers(f.at(4));

        // Every key: the letters so far. A next-word item is one call with nothing typed.
        std::vector<long> micros;
        harness::Output result;
        size_t shownAfter = 0;
        for (size_t n = item.typed.empty() ? 0 : 1; n <= item.typed.size(); n++) {
            harness::Item prefix{item.context, item.typed.substr(0, n),
                                 item.target,
                                 {item.xs.begin(), item.xs.begin() + n},
                                 {item.ys.begin(), item.ys.begin() + n}};
            const auto start = std::chrono::steady_clock::now();
            result = stack->run(prefix);
            micros.push_back(std::chrono::duration_cast<std::chrono::microseconds>(
                                 std::chrono::steady_clock::now() - start).count());
            const auto top = result.strip.begin() + std::min<size_t>(3, result.strip.size());
            if (!shownAfter && n > 0 && std::find(result.strip.begin(), top, item.target) != top) shownAfter = n;
        }

        std::string top3, times;
        for (size_t i = 0; i < result.strip.size() && i < 3; i++) top3 += (i ? "," : "") + result.strip[i];
        for (size_t i = 0; i < micros.size(); i++) times += (i ? "," : "") + std::to_string(micros[i]);
        out << item.typed << '\t' << item.target << '\t' << result.committed << '\t' << top3 << '\t' << times << '\t'
            << shownAfter << '\n';
    }
    return 0;
}
