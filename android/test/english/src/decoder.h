// Pristine AOSP LatinIME's decoder driven through its own JNI entry points.
#pragma once

#include <string>
#include <vector>

#include "harness.h"

namespace harness {

// SuggestedWordInfo's kinds and flags, the same in both decoders.
constexpr int KIND_MASK_KIND = 0xFF;
constexpr int KIND_TYPED = 0;
constexpr int KIND_WHITELIST = 3;
constexpr int KIND_SHORTCUT = 7;
constexpr int KIND_PREDICTION = 8;
constexpr int KIND_FLAG_EXACT_MATCH = 0x40000000;
constexpr int KIND_FLAG_APPROPRIATE_FOR_AUTO_CORRECTION = 0x10000000;

// The keyboard of layout.tsv as the app hands it over: key rectangles, the 32 x 16 proximity grid with the
// keys within 1.2 key widths of each cell, and touch position correction (the "holo" data both apps load).
long long makeProximityInfo(const std::string &jniPackage, const std::string &layoutPath);

class Decoder {
public:
    // JNI_PACKAGE: "com/android/inputmethod". MAX_RESULTS: the decoder's own.
    Decoder(const std::string &jniPackage, int maxResults, const std::string &dictPath, long long proximityInfo);
    // The dictionary's suggestions for ITEM's typed letters after the previous words of its context, as
    // BinaryDictionary.getSuggestions returns them (scores at locale weight 1.0).
    std::vector<Word> suggest(const Item &item) const;
    float normalizedScore(const std::string &typed, const std::string &word, int score) const;

private:
    std::string mPackage;
    int mMaxResults;
    long long mDict = 0, mSession = 0, mProximityInfo;
};

// SuggestionResults: the best CAPACITY words by score, then shorter first, then alphabetically; a word
// that ties another on all three is dropped, as in the TreeSet it is in both apps.
void addResult(std::vector<Word> &results, const Word &w, size_t capacity);

// Up to three words before the cursor in the last line of CONTEXT, nearest first, as NgramContext does:
// a word ending a sentence (or no word) gives beginning-of-sentence; a word ending in other punctuation
// ends the context.
struct PrevWords {
    std::vector<std::string> words;
    std::vector<bool> beginningOfSentence;
};
PrevWords prevWords(const std::string &context);

}  // namespace harness
