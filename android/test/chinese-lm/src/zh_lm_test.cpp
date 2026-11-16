// zh_lm's checks (bench.sh runs them before the sets): a tree of candidates larger than one batch scores as
// each candidate does alone.
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
    // Ten texts of 52 characters, each starting with another one: 520 tree nodes, over the 512 of a batch.
    const std::string chars = "我们今天下午去公园散步然后一起吃晚饭看电影聊天说话回家休息睡觉明早起床上班工作学习读书写字跑步游泳唱歌跳舞画画";
    std::vector<std::string> cps;
    for (size_t i = 0; i < chars.size(); i += 3) cps.push_back(chars.substr(i, 3));
    std::vector<std::string> texts;
    for (size_t t = 0; t < 10; t++) {
        std::string text;
        for (size_t c = 0; c < 52; c++) text += cps[(t + c) % cps.size()];
        texts.push_back(text);
    }
    const std::string context = "今天天气很好", typed = "women";
    model.prime(context);
    const auto together = model.score(context, typed, texts);
    int failed = 0;
    for (size_t t = 0; t < texts.size(); t++) {
        const float alone = model.score(context, typed, {texts[t]})[0];
        // Batch shapes move a score by about 0.01 nats a token (0.6 for one of these 53 tokens); a node read
        // with another's logits moves it by several.
        if (!(std::fabs(together[t] - alone) < 1.0f)) {
            fprintf(stderr, "text %zu: %.3f in the tree, %.3f alone\n", t, together[t], alone);
            failed++;
        }
    }
    printf("%s: a tree of %zu nodes scores as its texts alone\n", failed ? "FAIL" : "PASS", texts.size() * 52);
    return failed ? 1 : 0;
}
