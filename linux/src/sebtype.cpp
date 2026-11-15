// SebType's Fcitx5 input method: keys go to SebType's core, and what it says is drawn with Fcitx5's own
// input panel (classicui: the candidate window and the switch popup). MIT, SebType.
#include "sebtype.h"

#include <fcitx-utils/i18n.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/standardpaths.h>
#include <fcitx/candidatelist.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/inputpanel.h>
#include <fcitx/text.h>
#include <sebtype/hosts.h>

#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>

#include "dbus_public.h"
#include "tray.h"

#ifndef SEBTYPE_MOZC_SERVER
#define SEBTYPE_MOZC_SERVER "/usr/libexec/sebtype/mozc_server"
#endif

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

// Mozc's own profile folder (base/system_util.cc): ~/.mozc when it exists, else XDG's.
std::string mozcProfile() {
  fs::path old = fs::path(env("HOME", "")) / ".mozc";
  return fs::is_directory(old) ? old.string() : (configHome() / "mozc").string();
}

std::unique_ptr<Engine> makeEngine(Lang lang) {
  const auto rimeUser = fcitx::StandardPaths::global().userDirectory(fcitx::StandardPathsType::PkgData) / "rime";
  if (lang == Lang::Chinese) {
    fs::create_directories(rimeUser);
    return makeRime({RIME_DATA_DIR, rimeUser.string()});
  }
  return makeMozc({env("SEBTYPE_MOZC_SERVER", SEBTYPE_MOZC_SERVER), mozcProfile(), rimeUser.string()});
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

}  // namespace

std::tuple<std::string, bool, bool, std::string> Service::state() {
  auto &core = engine_->core();
  return {langId(core.language()), core.latin(), core.alternate(), SebTypeEngine::iconName(core.icon())};
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
  const auto &raw = event.rawKey();
  if (core_->key({static_cast<uint32_t>(raw.sym()), coreMods(raw.states()), event.isRelease()})) {
    event.filterAndAccept();
  }
  update(event.inputContext());
}

void SebTypeEngine::activate(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
  update(event.inputContext());
}

void SebTypeEngine::reset(const fcitx::InputMethodEntry &, fcitx::InputContextEvent &event) {
  core_->focusOut();
  update(event.inputContext());
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

void SebTypeEngine::save() {
  core_->forEachEngine([](Engine &e) { e.save(); });
}

void SebTypeEngine::setSubConfig(const std::string &path, const fcitx::RawConfig &) {
  if (path == "deploy") {
    core_->engine(Lang::Chinese);
    core_->forEachEngine([](Engine &e) { e.deploy(); });  // Rime's, and Mozc's page size
  }
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
    fcitx::Text text;
    for (const auto &s : p.segments) {
      fcitx::TextFormatFlags flags;
      if (s.underline) flags |= fcitx::TextFormatFlag::Underline;
      if (s.highlight) flags |= fcitx::TextFormatFlag::HighLight;
      text.append(s.text, flags);
    }
    text.setCursor(p.cursor);
    if (ic->capabilityFlags().test(fcitx::CapabilityFlag::Preedit)) panel.setClientPreedit(text);
    else panel.setPreedit(text);
    if (auto aux = core_->aux(); !aux.empty()) panel.setAuxUp(fcitx::Text(aux));
    if (const Page page = core_->page(); !page.empty()) panel.setCandidateList(std::make_unique<List>(this, ic, page));
    if (auto commit = core_->takeCommit(); !commit.empty()) ic->commitString(commit);
    ic->updatePreedit();
    ic->updateUserInterface(fcitx::UserInterfaceComponent::InputPanel);
    const auto &config = instance_->globalConfig();
    if (auto notice = core_->takeNotice(config.compactInputMethodInformation());
        !notice.empty() && config.showInputMethodInformation())
      instance_->showCustomInputMethodInformation(ic, notice);
  }
  // The tray and Plasma's input method panel read the icon and menu again.
  if (auto icon = core_->icon(); ic && icon != lastIcon_) {
    lastIcon_ = icon;
    ic->updateUserInterface(fcitx::UserInterfaceComponent::StatusArea);
  }
  if (auto *tray = dynamic_cast<NotificationItem *>(instance_->addonManager().addon("notificationitem"))) tray->update();
}

class SebTypeFactory : public fcitx::AddonFactory {
  fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
    return new SebTypeEngine(manager->instance());
  }
};

}  // namespace sebtype

FCITX_ADDON_FACTORY_V2(sebtype, sebtype::SebTypeFactory)
