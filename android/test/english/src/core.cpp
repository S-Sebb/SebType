// The new keyboard's English (#244): core/src/english.cpp, AOSP's decoder on the rebuilt dictionary with
// SebType's model, driven as the keyboard drives it: the text before the word, then one key at a time.
#include <algorithm>
#include <condition_variable>
#include <fstream>
#include <mutex>
#include <sstream>
#include <stdexcept>

#include <sebtype/hosts.h>

#include "harness.h"

namespace harness {
namespace {

constexpr uint32_t BackSpace = 0xff08;

sebtype::Layout readLayout(const std::string &path) {
    std::ifstream in(path);
    if (!in) throw std::runtime_error("can't read " + path);
    sebtype::Layout layout;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream f(line);
        std::string name;
        sebtype::KeyRect k;
        f >> name >> k.x >> k.y >> k.width >> k.height;
        layout.width = std::max(layout.width, k.x + k.width);
        layout.height = std::max(layout.height, k.y + k.height);
        if (name == "space" || name.size() == 1) {  // function keys stay out, as the app leaves them
            k.code = name == "space" ? U' ' : char32_t(name[0]);
            layout.keys.push_back(k);
        }
    }
    return layout;
}

class CoreStack : public Stack {
public:
    CoreStack(const std::string &layout, const std::string &dict, const std::string &model) {
        mEngine = sebtype::makeEnglish({dict, 0, 0, model, ""}, [this] {
            std::lock_guard g(mMutex);
            mReadies++;
            mReady.notify_all();
        });
        mEngine->setLayout(readLayout(layout));
        // The model loads on the first letter: typed and deleted, as a user's first word would load it.
        const int before = readies();
        mEngine->key({'a', 0, false});
        mEngine->key({BackSpace, 0, false});
        waitReady(before);
    }

    // The field's text before the word, and its next words computed (the user reads them before typing).
    void begin(const Item &item) override {
        const int before = readies();
        mEngine->setContext(item.context.empty() ? "" : item.context + " ");
        waitReady(before);
    }

    Output run(const Item &item) override {
        const size_t n = item.typed.size();
        Output out;
        if (n == 0) {  // a next-word item, timed from the text's change to its words
            begin(item);
            for (const auto &c : mEngine->candidates(3)) out.strip.push_back(c.text);
            return out;
        }
        // The letter shows the decoder's strip at once; the model's ranking follows through READY (#310), and
        // it is what the user reads, so the time per key runs until it comes.
        const int before = readies();
        mEngine->key({uint32_t(static_cast<unsigned char>(item.typed[n - 1])), 0, false, item.xs[n - 1], item.ys[n - 1]});
        waitReady(before);
        const auto list = mEngine->candidates(20);
        out.committed = mEngine->highlighted() >= 0 ? list.at(mEngine->highlighted()).text : item.typed;
        for (const auto &c : list)
            if (c.text != item.typed) out.strip.push_back(c.text);
        return out;
    }

private:
    int readies() {
        std::lock_guard g(mMutex);
        return mReadies;
    }
    void waitReady(int after) {
        std::unique_lock l(mMutex);
        if (!mReady.wait_for(l, std::chrono::minutes(2), [&] { return mReadies > after; }))
            throw std::runtime_error("core stack: no READY after two minutes");
    }

    std::mutex mMutex;
    std::condition_variable mReady;
    int mReadies = 0;
    std::unique_ptr<sebtype::Engine> mEngine;
};

}  // namespace

std::unique_ptr<Stack> makeStack(const std::vector<std::string> &args) {
    if (args.size() != 3) throw std::runtime_error("core stack: LAYOUT DICT MODEL");
    return std::make_unique<CoreStack>(args[0], args[1], args[2]);
}

}  // namespace harness
