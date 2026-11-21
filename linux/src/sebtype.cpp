// SebType's Fcitx5 input method: keys go to SebType's core, and what it says is drawn with Fcitx5's own
// input panel (classicui: the candidate window and the switch popup). MIT, SebType.
#include "sebtype.h"

#include <fcitx-utils/i18n.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpaths.h>
#include <fcitx-utils/utf8.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/text.h>
#include <sebtype/hosts.h>

#include <algorithm>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "dbus_public.h"
#include "tray.h"

namespace sebtype {

namespace {

namespace fs = std::filesystem;

std::string env(const char *name, std::string fallback) {
  const char *v = std::getenv(name);
  return v && *v ? v : fallback;
}

fs::path configHome() { return env("XDG_CONFIG_HOME", env("HOME", "") + "/.config"); }
fs::path settingsPath() { return configHome() / "sebtype" / "sebtype.conf"; }

Settings readSettings() {
  std::ifstream f(settingsPath());
  std::stringstream s;
  s << f.rdbuf();
  return Settings::parse(s.str());
}

// Mozc's own profile folder (base/system_util.cc): ~/.mozc when it exists, else XDG's. The Configurator
// (pc/configurator/src/linux.rs) and setup-ime.sh use the same rule (#274).
std::string mozcProfile() {
  fs::path old = fs::path(env("HOME", "")) / ".mozc";
  return fs::is_directory(old) ? old.string() : (configHome() / "mozc").string();
}

std::unique_ptr<Engine> makeEngine(Lang lang) {
  if (lang == Lang::English) return nullptr;  // keys go to the app as typed
  const auto rimeUser = fcitx::StandardPaths::global().userDirectory(fcitx::StandardPathsType::PkgData) / "rime";
  if (lang == Lang::Chinese) {
    fs::create_directories(rimeUser);
    return makeRime({RIME_DATA_DIR, rimeUser.string()});
  }
  return makeMozc({mozcProfile(), rimeUser.string()});
}

Lang langFromId(const std::string &id) {
  for (Lang l : {Lang::English, Lang::Chinese, Lang::Japanese})
    if (id == langId(l)) return l;
  return Lang::English;
}

class Word final : public fcitx::CandidateWord {
 public:
  Word(SebTypeEngine *engine, int index, const Candidate &c) : engine_(engine), index_(index) {
    setText(fcitx::Text(c.text));
    if (!c.comment.empty()) setComment(fcitx::Text(c.comment));
  }
  void select(fcitx::InputContext *ic) const override {
    engine_->core().select(index_);
    engine_->update(ic);
  }

 private:
  SebTypeEngine *engine_;
  int index_;
};

// One page from the core; the window's direction is classicui's (the Configurator's setting).
class List final : public fcitx::CandidateList, public fcitx::PageableCandidateList {
 public:
  List(SebTypeEngine *engine, fcitx::InputContext *ic, const Page &page)
      : engine_(engine), ic_(ic), cursor_(page.cursor), hasPrev_(page.hasPrev), hasNext_(page.hasNext) {
    setPageable(this);
    for (size_t i = 0; i < page.items.size(); ++i) {
      words_.push_back(std::make_unique<Word>(engine, static_cast<int>(i), page.items[i]));
      labels_.emplace_back(i < page.labels.size() ? page.labels[i] : "");
    }
  }
  const fcitx::Text &label(int idx) const override { return labels_.at(idx); }
  const fcitx::CandidateWord &candidate(int idx) const override { return *words_.at(idx); }
  int size() const override { return static_cast<int>(words_.size()); }
  int cursorIndex() const override { return cursor_; }
  fcitx::CandidateLayoutHint layoutHint() const override { return fcitx::CandidateLayoutHint::NotSet; }
  bool hasPrev() const override { return hasPrev_; }
  bool hasNext() const override { return hasNext_; }
  void prev() override { page(false); }
  void next() override { page(true); }
  bool usedNextBefore() const override { return true; }

 private:
  void page(bool next) {
    engine_->core().changePage(next);
    engine_->update(ic_);
  }
  SebTypeEngine *engine_;
  fcitx::InputContext *ic_;
  std::vector<std::unique_ptr<Word>> words_;
  std::vector<fcitx::Text> labels_;
  int cursor_;
  bool hasPrev_, hasNext_;
};

uint32_t coreMods(fcitx::KeyStates s) {
  uint32_t m = 0;
  if (s.test(fcitx::KeyState::Shift)) m |= mod::Shift;
  if (s.test(fcitx::KeyState::CapsLock)) m |= mod::Lock;
  if (s.test(fcitx::KeyState::Ctrl)) m |= mod::Ctrl;
  if (s.test(fcitx::KeyState::Alt)) m |= mod::Alt;
  if (s.test(fcitx::KeyState::Super) || s.test(fcitx::KeyState::Super2)) m |= mod::Super;
  return m;
}

// Where the popup can go. Fcitx5 places it at the cursor the app gave, and at the screen's top-left corner
// when there is none (#446: Win+Space in a window with no text field); the tray's icon says the switch then.
// On Wayland's input method protocols the compositor places it and the app's cursor is never Fcitx5's.
bool hasCaret(fcitx::InputContext *ic) {
  return ic->frontendName().starts_with("wayland") || ic->cursorRect() != fcitx::Rect();
}

}  // namespace

// Nothing typed in a password field or one the app calls sensitive is learned (#270), and the field keeps
// what was learned before. Qt's ImhSensitiveData and text-input-v3's sensitive hint arrive as Sensitive:
// Chromium sets it in incognito windows on Wayland. Firefox's private windows set no hint on Linux, and
// fcitx5-gtk drops GTK's private hint.
void SebTypeEngine::followField(fcitx::InputContext *ic) {
  const bool learning = !ic->capabilityFlags().testAny(fcitx::CapabilityFlag::PasswordOrSensitive);
  if (learning != core_->fieldLearning()) core_->setField(Field::Text, learning);
}

std::tuple<std::string, bool, bool, std::string> Service::state() {
  auto &core = engine_->core();
  return {langId(core.language()), core.latin(), core.alternate(), SebTypeEngine::iconName(core.icon())};
}

std::string Service::forget(const std::string &id) {
  if (id != "zh" && id != "ja") return "no language to forget: '" + id + "' (zh or ja)";  // English learns nothing
  return engine_->forget(langFromId(id));
}

void Service::setLanguage(const std::string &id) {
  engine_->core().selectLanguage(langFromId(id));
  engine_->update(engine_->instance()->mostRecentInputContext());
}

SebTypeEngine::SebTypeEngine(fcitx::Instance *instance)
    : instance_(instance), core_(std::make_unique<Core>(makeEngine, readSettings())) {
  core_->setUiLanguage(systemLanguage());
  if (auto *dbus = instance_->addonManager().addon("dbus")) {
    service_ = std::make_unique<Service>(this);
    dbus->call<fcitx::IDBusModule::bus>()->addObjectVTable("/sebtype", "org.sebtype.Core1", *service_);
  }
}

SebTypeEngine::~SebTypeEngine() = default;

// The entry's language is the current one (en, zh or ja), as keyboard-us's, rime's and mozc's were: classicui
// gives it to Pango (UseInputMethodLanguageToDisplayText), which picks the Chinese or Japanese forms of a glyph.
fcitx::InputMethodEntry SebTypeEngine::entry() const {
  fcitx::InputMethodEntry entry("sebtype", "SebType", langId(core_->language()), "sebtype");
  entry.setIcon(iconName("en")).setLabel("SebType");
  return entry;
}

std::vector<fcitx::InputMethodEntry> SebTypeEngine::listInputMethods() {
  std::vector<fcitx::InputMethodEntry> entries;
  entries.push_back(entry());
  return entries;
}

void SebTypeEngine::keyEvent(const fcitx::InputMethodEntry &, fcitx::KeyEvent &event) {
  followField(event.inputContext());
  const auto &raw = event.rawKey();
  // 日本語's undo of a commit (#376) deletes it only where the app gives the text before the cursor, and so can
  // delete it too.
  if (auto *ic = event.inputContext(); raw.sym() == FcitxKey_BackSpace && raw.states().test(fcitx::KeyState::Ctrl) &&
                                       !event.isRelease() &&
                                       ic->capabilityFlags().test(fcitx::CapabilityFlag::SurroundingText)) {
    const auto &st = ic->surroundingText();
    if (st.isValid()) {
      const std::string &text = st.text();
      const auto cursor = std::min<size_t>(st.cursor(), fcitx::utf8::length(text));
      core_->setContext(text.substr(0, fcitx::utf8::ncharByteLength(text.begin(), cursor)), {},
                        st.anchor() != st.cursor());
    }
  }
  const Key key{static_cast<uint32_t>(raw.sym()), coreMods(raw.states()), event.isRelease()};
  if (typesText(key)) shownUntil_ = 0;  // typing ends the popup at once (#449)
  if (core_->key(key)) event.filterAndAccept();
  update(event.inputContext());
}

void SebTypeEngine::activate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
  followField(event.inputContext());
  update(event.inputContext());
}

bool SebTypeEngine::preeditInPanel(fcitx::InputContext *ic) const {
  return (core_->language() == Lang::Chinese && core_->settings().pinyinRow) ||
         !ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit);
}

// Focus moving away, the app's reset (a click elsewhere in the text) or another input method types in what is
// being typed (#277): the app, or Fcitx5 for it, types in the preedit it shows (update() marks what it leaves
// out), so the core only drops it. A preedit in Fcitx5's own panel SebType types in itself.
void SebTypeEngine::reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
  if (preeditInPanel(event.inputContext())) core_->focusOut();
  else core_->clear();
  update(event.inputContext());
}

void SebTypeEngine::deactivate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) {
  reset(entry, event);
}

std::string SebTypeEngine::subModeIconImpl(const fcitx::InputMethodEntry &, fcitx::InputContext &) {
  return iconName(core_->icon());
}

std::string SebTypeEngine::subModeLabelImpl(const fcitx::InputMethodEntry &, fcitx::InputContext &) {
  return langName(core_->language());
}

std::string SebTypeEngine::subMode(const fcitx::InputMethodEntry &, fcitx::InputContext &) {
  return langName(core_->language());
}

void SebTypeEngine::reloadConfig() {
  core_->setSettings(readSettings());
  update(instance_->mostRecentInputContext());
}

// Fcitx5's autosave and the sync's Save (#373): Rime's save ends its session, so it waits until typing is idle.
// Fcitx5's own save before it exits is done at once.
void SebTypeEngine::save() {
  if (instance_->exiting()) return core_->forEachEngine([](Engine &e) { e.save(); });
  whenIdle(Core::Chore::Save, [this] { core_->forEachEngine([](Engine &e) { e.save(); }); });
}

// The Configurator's changes deploy or restart Mozc at once. A sync's pull asks with -when-idle: those drop
// what is being typed, so they wait until typing is idle (#373).
void SebTypeEngine::setSubConfig(const std::string &path, const fcitx::RawConfig &) {
  const auto deploy = [this] {
    core_->engine(Lang::Chinese);
    core_->forEachEngine([](Engine &e) { e.deploy(); });  // Rime's, and Mozc's page size
    updateStatus(instance_->mostRecentInputContext());
  };
  // Mozc reads its settings and dictionaries when it starts: it saves and closes, and the next 日本語 key starts
  // it again.
  const auto restartMozc = [this] {
    core_->stop(Lang::Japanese);
    update(instance_->mostRecentInputContext());
  };
  if (path == "deploy") deploy();
  else if (path == "mozc") restartMozc();
  else if (path == "deploy-when-idle") whenIdle(Core::Chore::Deploy, deploy);
  else if (path == "mozc-when-idle") whenIdle(Core::Chore::ReloadJapanese, restartMozc);
}

void SebTypeEngine::whenIdle(Core::Chore chore, std::function<void()> work) {
  core_->whenIdle(chore, std::move(work));
  if (chores_) {
    chores_->setNextInterval(0);
    chores_->setOneShot();
    return;
  }
  chores_ = instance_->eventLoop().addTimeEvent(
      CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC), 0, [this](fcitx::EventSourceTime *source, uint64_t) {
        if (core_->runChores()) {
          source->setNextInterval(1000000);
          source->setOneShot();
        }
        return true;
      });
}

std::string SebTypeEngine::forget(Lang lang) {
  Engine *e = core_->engine(lang);
  e->forget();
  update(instance_->mostRecentInputContext());
  updateStatus(instance_->mostRecentInputContext());
  return e->forgetError();
}

void SebTypeEngine::update(fcitx::InputContext *ic) {
  // Fcitx5 has no setter for an entry's language, so the entry it keeps is replaced in place.
  if (const auto *current = instance_->inputMethodManager().entry("sebtype");
      current && current->languageCode() != langId(core_->language()))
    const_cast<fcitx::InputMethodEntry &>(*current) = entry();
  if (ic) {
    auto &panel = ic->inputPanel();
    panel.reset();
    const Preedit p = core_->preedit();
    // What focus moving away types in leaves out some of what shows (Rime's spaces between syllables): those
    // bytes don't commit. It is the rest of the preedit, in order.
    const std::string typed = core_->unfinished();
    const bool inPanel = preeditInPanel(ic), pinyinRow = inPanel && core_->language() == Lang::Chinese;
    size_t at = 0;
    fcitx::Text text;
    for (const auto &s : p.segments) {
      fcitx::TextFormatFlags flags;
      if (s.underline && !pinyinRow) flags |= fcitx::TextFormatFlag::Underline;
      if (s.highlight) flags |= fcitx::TextFormatFlag::HighLight;
      for (size_t from = 0, to; from < s.text.size(); from = to) {
        const bool kept = at < typed.size() && s.text[from] == typed[at];
        for (to = from; to < s.text.size() && (at < typed.size() && s.text[to] == typed[at]) == kept; ++to)
          if (kept) ++at;
        text.append(s.text.substr(from, to - from), kept ? flags : flags | fcitx::TextFormatFlag::DontCommit);
      }
    }
    // The pinyin row is Windows' (#447): no underline, nor the cursor Rime keeps at the start.
    text.setCursor(pinyinRow ? -1 : p.cursor);
    if (inPanel) panel.setPreedit(text);
    else panel.setClientPreedit(text);
    const auto aux = core_->aux();
    const Page page = core_->page();
    if (!aux.empty()) panel.setAuxUp(fcitx::Text(aux));
    if (!page.empty()) panel.setCandidateList(std::make_unique<List>(this, ic, page));
    // The key's release resets the panel too: a popup still showing over an empty panel stays for its
    // second (Fcitx5 hides it only while it is the panel's sole text). A new popup replaces it: Fcitx5
    // shows its popup (the overlay message) only over an empty panel (#387).
    const uint64_t now = fcitx::now(CLOCK_MONOTONIC);
    const auto &config = instance_->globalConfig();
    auto notice = core_->takeNotice(config.compactInputMethodInformation());
    if (!config.showInputMethodInformation() || !hasCaret(ic)) notice.clear();
    if (notice.empty() && aux.empty() && page.empty() && p.segments.empty() && now < shownUntil_) {
      panel.setAuxUp(fcitx::Text(shown_));
      hidePopupLater(ic);
    }
    // 日本語's undo of a commit (Ctrl+Backspace) deletes it: the characters before the cursor.
    if (const int n = core_->takeEdit().deleteBefore) ic->deleteSurroundingText(-n, n);
    if (auto commit = core_->takeCommit(); !commit.empty()) ic->commitString(commit);
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    if (!notice.empty()) {
      instance_->showCustomInputMethodInformation(ic, notice);
      shown_ = notice;
      shownUntil_ = now + 1000000;
      hidePopupLater(ic);
    }
  }
  updateStatus(ic);
}

void SebTypeEngine::hidePopupLater(fcitx::InputContext *ic) {
  hide_ = instance_->eventLoop().addTimeEvent(
      CLOCK_MONOTONIC, shownUntil_, 0, [this, ref = ic->watch()](fcitx::EventSourceTime *, uint64_t) {
        hidePopup(ref.get());
        return true;
      });
}

void SebTypeEngine::hidePopup(fcitx::InputContext *ic) {
  shownUntil_ = 0;
  if (!ic || shown_.empty() || ic->inputPanel().auxUp().toString() != shown_) return;
  ic->inputPanel().setAuxUp(fcitx::Text());
  ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
}

void SebTypeEngine::updateStatus(fcitx::InputContext *ic) {
  const auto icon = core_->icon();
  if (ic && icon != lastIcon_) {
    lastIcon_ = icon;
    ic->updateUserInterface(fcitx::UserInterfaceComponent::StatusArea);
  }
  if (auto *tray = dynamic_cast<NotificationItem *>(instance_->addonManager().addon("notificationitem"))) tray->update();
  if (!icon.ends_with("-wait") || (poll_ && poll_->isEnabled())) return;
  if (poll_) {
    poll_->setNextInterval(500000);
    poll_->setOneShot();
    return;
  }
  poll_ = instance_->eventLoop().addTimeEvent(
      CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + 500000, 0, [this](fcitx::EventSourceTime *source, uint64_t) {
        updateStatus(instance_->mostRecentInputContext());
        if (core_->icon().ends_with("-wait")) {
          source->setNextInterval(500000);
          source->setOneShot();
        } else {
          hidePopup(instance_->mostRecentInputContext());  // its "getting ready" is over
        }
        return true;
      });
}

class SebTypeFactory : public fcitx::AddonFactory {
  fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
    return new SebTypeEngine(manager->instance());
  }
};

}  // namespace sebtype

FCITX_ADDON_FACTORY_V2(sebtype, sebtype::SebTypeFactory)
