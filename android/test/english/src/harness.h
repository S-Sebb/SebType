// The English harness (#231): one test item in, the suggestion strip and the committed word out.
#pragma once

#include <memory>
#include <string>
#include <vector>

namespace harness {

struct Item {
    std::string context;  // the sentence before the word, without the trailing space
    std::string typed;    // the letters typed; empty for a next-word prediction
    std::string target;   // the word the user meant
    std::vector<int> xs, ys;  // one touch point per typed letter, in layout.tsv's pixels
};

struct Word {
    std::string word;
    int score;
    int kind;  // SuggestedWordInfo's kind and flags
};

struct Output {
    std::vector<std::string> strip;  // the suggestions, best first, without the typed word itself
    std::string committed;           // what a space commits: the autocorrection, or the typed word
};

// One English stack: pristine AOSP's decoder, alone or with SebType's model, or core/'s English.
class Stack {
public:
    virtual ~Stack() = default;
    // The strip and the committed word once ITEM's letters are typed. Called for each letter in turn, as
    // the keyboard asks on every key; a new context means a new item.
    virtual Output run(const Item &item) = 0;
    // Before the first letter of a typed item, untimed: what the keyboard does before the user types (the
    // core stack sets the field's text and lets its next words come).
    virtual void begin(const Item & /*item*/) {}
};

// Made by aosp.cpp, sebtype.cpp or core.cpp, whichever the executable is built with. ARGS: the files it loads.
std::unique_ptr<Stack> makeStack(const std::vector<std::string> &args);

}  // namespace harness
