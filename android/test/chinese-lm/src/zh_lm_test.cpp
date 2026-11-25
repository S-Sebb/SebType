// zh_lm's checks (bench.sh runs them before the sets): a tree of candidates larger than one batch scores as
// each candidate does alone, one larger than the cache leaves texts out instead of failing, and plain() keeps
// score()'s example in the cache.
// MIT, SebType.
//
//   zh_lm_test MODEL.gguf
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "zh_lm.h"

int main(int argc, char **argv) {
    if (argc != 2) return fprintf(stderr, "usage: zh_lm_test MODEL.gguf\n"), 2;
    zh_lm::Model model(argv[1]);
    // Six texts of 40 characters, each starting with another one: 240 tree nodes (the most it takes), over the
    // 256 tokens of a batch with the example's.
    const std::string chars = "我们今天下午去公园散步然后一起吃晚饭看电影聊天说话回家休息睡觉明早起床上班工作学习读书写字跑步游泳唱歌跳舞画画";
    std::vector<std::string> cps;
    for (size_t i = 0; i < chars.size(); i += 3) cps.push_back(chars.substr(i, 3));
    std::vector<std::string> texts;
    for (size_t t = 0; t < 6; t++) {
        std::string text;
        for (size_t c = 0; c < 40; c++) text += cps[(t + c) % cps.size()];
        texts.push_back(text);
    }
    const std::string context = "今天天气很好", typed = "women";
    model.prime(context);
    const auto together = model.score(context, typed, texts);
    int failed = 0;
    for (size_t t = 0; t < texts.size(); t++) {
        const float alone = model.score(context, typed, {texts[t]})[0];
        // Batch shapes move a score by up to about 0.03 nats a token (1.1 for one of these 41 tokens with #557's
        // checkpoints, 0.07 with r2's); a node read with another's logits moves it by several.
        if (!(std::fabs(together[t] - alone) < 2.0f)) {
            fprintf(stderr, "text %zu: %.3f in the tree, %.3f alone\n", t, together[t], alone);
            failed++;
        }
    }
    printf("%s: a tree of %zu nodes scores as its texts alone\n", failed ? "FAIL" : "PASS", texts.size() * 40);
    // A seventh text doesn't fit: it scores -inf, the others as before.
    std::string reversed;
    for (size_t c = 40; c-- > 0;) reversed += cps[c % cps.size()];
    texts.push_back(reversed);
    const auto over = model.score(context, typed, texts);
    const bool left = std::isinf(over.back()) && std::fabs(over[0] - together[0]) < 1.0f;
    printf("%s: a text over the tree's room is left out\n", left ? "PASS" : "FAIL");
    failed += !left;
    // plain() after score() decodes aside, keeping score()'s example in the cache (#502): it scores as it does
    // right after prime(), and score() then scores as before. "Before" is score()'s second call: its first decodes
    // the example, in other batch shapes than a cached example's, which moves an unlikely text's score by about
    // 0.1 nats (#557's checkpoints).
    const std::vector<std::string> short_{"我们", "我门", "握们去"};
    model.prime(context);
    const auto fresh = model.plain(context, short_);
    model.score(context, typed, short_);
    const auto before = model.score(context, typed, short_);
    const auto aside = model.plain(context, short_);
    const auto after = model.score(context, typed, short_);
    bool same = true;
    for (size_t t = 0; t < short_.size(); t++) {
        if (std::fabs(fresh[t] - aside[t]) < 0.1f && std::fabs(before[t] - after[t]) < 0.1f) continue;
        fprintf(stderr, "%s: plain %.3f fresh, %.3f aside; score %.3f before, %.3f after\n", short_[t].c_str(),
                fresh[t], aside[t], before[t], after[t]);
        same = false;
    }
    printf("%s: plain() beside score()'s example changes neither\n", same ? "PASS" : "FAIL");
    failed += !same;
    return failed ? 1 : 0;
}
