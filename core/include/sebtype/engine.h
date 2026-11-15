// SebType core: what the core needs from a conversion engine (Rime for 中文, Mozc for 日本語). MIT, SebType.
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
  // Text to commit since the last call.
  virtual std::string takeCommit() = 0;
  virtual Preedit preedit() = 0;
  virtual std::string aux() { return {}; }
  virtual bool composing() = 0;
  // Commits what is being typed (leaving the language), or drops it (focus moved away).
  virtual void flush() = 0;
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
  // commit.
  virtual std::vector<Candidate> candidates(int max);
  virtual void setField(Field /*field*/) {}
  virtual void setKeys(Keys /*keys*/, bool /*landscape*/) {}
  virtual void moveCursor(int /*chars*/) {}
  virtual bool undo() { return false; }
  virtual Edit takeEdit() { return {}; }

  // The settings the engine applies itself; learning is off when the settings or the field say so.
  virtual void applySettings(const Settings & /*settings*/, bool /*learning*/) {}
  // Forgets what was learned from typing, where the engine keeps it itself (Mozc's history).
  virtual void forget() {}

  // Applies changed settings or data (Rime's deploy) and saves learned words (Rime's sync).
  virtual void deploy() {}
  virtual void save() {}
  // Still deploying or saving, in the engine's own thread.
  virtual bool busy() { return false; }
};

}  // namespace sebtype
