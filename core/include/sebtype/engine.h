// SebType core: what the core needs from an engine (Rime for 中文, Mozc for 日本語, English on the phone). MIT,
// SebType.
#pragma once

#include <sebtype/settings.h>
#include <sebtype/types.h>

#include <string>
#include <vector>

namespace sebtype {

class Engine {
 public:
  virtual ~Engine() = default;

  // A key the core passes on (never Shift, Ctrl or Alt alone: the core handles those). True when taken.
  virtual bool key(const Key &key) = 0;
  // The work a key left for after its text shows (English's suggestions for the letters typed, #310): does
  // it, and returns whether the candidates changed. The frontend calls it right after showing the key.
  virtual bool settle() { return false; }
  // Text to commit since the last call.
  virtual std::string takeCommit() = 0;
  virtual Preedit preedit() = 0;
  virtual std::string aux() { return {}; }
  virtual bool composing() = 0;
  // The keys typed as the engine keeps them (Rime's input: "nihao"), for a model around it.
  virtual std::string input() { return {}; }
  // What focus moving away types in (#277): the preedit as it shows.
  virtual std::string unfinished() { return preedit().text(); }
  // Commits what is being typed (leaving the language), or drops it.
  virtual void flush() = 0;
  // Commits the keys typed as they are (the phone's 🌐, #492): "phizz", not its pinyin split or kana. An engine
  // that keeps no keys drops them.
  virtual void flushInput() { clear(); }
  virtual void clear() = 0;

  // Candidates. Engines that hand the core their whole list are paged by the core (pager.h); an engine
  // that pages itself overrides page(), select() and changePage().
  virtual int pageSize() { return 0; }
  virtual bool candidateAt(int /*index*/, Candidate & /*out*/) { return false; }
  virtual int highlighted() { return -1; }  // in the whole list
  virtual void selectAt(int /*index*/) {}
  virtual void highlightAt(int /*index*/) {}
  virtual std::string label(int indexOnPage) { return std::to_string((indexOnPage + 1) % 10) + " "; }
  virtual Page page();
  virtual void select(int indexOnPage);
  virtual void changePage(bool next);

  // The English mode inside the language, which the Shift tap toggles.
  virtual bool latin() = 0;
  virtual void setLatin(bool on) = 0;
  // How a tap of this Shift key (Shift_L or Shift_R) switches: false when it doesn't.
  virtual bool shiftTapSwitches(uint32_t /*sym*/) { return true; }
  // The language's one switch: 简 → 繁 in 中文, あ → ア in 日本語.
  virtual bool alternate() = 0;
  virtual void setAlternate(bool on) = 0;

  // Touch keyboards: the whole list up to max (by default from candidateAt), the field, the keys on screen,
  // the cursor moved inside the preedit (to a character from its start), undo, and the edit around a
  // commit (the PCs too: 日本語's undo deletes its commit).
  virtual std::vector<Candidate> candidates(int max);
  // The phone's setup self-test (ranh → 然后): the engine's own list, up to max, for TEXT typed into an
  // empty composition. What it typed goes again, and the field goes back to FIELD.
  virtual std::vector<Candidate> tryTyping(const std::string &text, int max, Field field);
  virtual void setField(Field /*field*/) {}
  virtual void setKeys(Keys /*keys*/, bool /*landscape*/) {}
  // English: the keys' rectangles, and the field's text around the cursor whenever it changed other than by
  // this engine's commits and the keys it was given (focus, a cursor move, the app's own edit): before it,
  // the start of what follows it, and whether text is selected.
  virtual void setLayout(const Layout & /*layout*/) {}
  virtual void setContext(const std::string & /*before*/, const std::string & /*after*/ = {}, bool /*selection*/ = false) {}
  virtual void moveCursor(int /*chars*/) {}
  virtual bool undo() { return false; }
  virtual Edit takeEdit() { return {}; }

  // The settings the engine applies itself; learning is off when the settings or the field say so.
  virtual void applySettings(const Settings & /*settings*/, bool /*learning*/) {}
  // Forgets what was learned from typing, where the engine keeps it itself (Mozc's history; on the PCs also
  // Rime's user dictionaries): it closes its files, deletes them and opens new ones, so nothing learned comes
  // back, while typing or after a restart (#375). A Mozc that loads in the background does it there, busy()
  // until done.
  virtual void forget() {}
  // Why the last forget() left something learned behind (a file it couldn't delete or a folder it couldn't
  // read), once it isn't busy(); empty when it forgot everything.
  virtual std::string forgetError() const { return {}; }
  // Reads its files again, which another program changed (Mozc's dictionary and settings); what was being
  // typed goes.
  virtual void reload() {}

  // Applies changed settings or data (Rime's deploy) and saves learned words (Rime's sync).
  virtual void deploy() {}
  virtual void save() {}
  // Still loading, deploying or saving, in the engine's own thread.
  virtual bool busy() { return false; }
  // False when it can't take keys and isn't busy: it didn't load (#275).
  virtual bool available() { return true; }
};

}  // namespace sebtype
