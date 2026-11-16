// SebType's Fcitx5 add-on: one input method over SebType's core, which switches English, 中文 and 日本語
// itself, and the tray item with SebType's menu. MIT, SebType.
#pragma once

#include <fcitx-utils/dbus/objectvtable.h>
#include <fcitx-utils/event.h>
#include <fcitx/addonfactory.h>
#include <fcitx/addoninstance.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputmethodengine.h>
#include <fcitx/instance.h>
#include <sebtype/core.h>

#include <memory>
#include <string>

namespace sebtype {

class SebTypeEngine;

// State for tests and tools, on Fcitx5's bus at /sebtype.
class Service : public fcitx::dbus::ObjectVTable<Service> {
 public:
  explicit Service(SebTypeEngine *engine) : engine_(engine) {}
  std::tuple<std::string, bool, bool, std::string> state();
  void setLanguage(const std::string &id);

 private:
  FCITX_OBJECT_VTABLE_METHOD(state, "State", "", "sbbs");
  FCITX_OBJECT_VTABLE_METHOD(setLanguage, "SetLanguage", "s", "");
  SebTypeEngine *engine_;
};

class SebTypeEngine final : public fcitx::InputMethodEngineV2 {
 public:
  explicit SebTypeEngine(fcitx::Instance *instance);
  ~SebTypeEngine() override;

  std::vector<fcitx::InputMethodEntry> listInputMethods() override;
  void keyEvent(const fcitx::InputMethodEntry &entry, fcitx::KeyEvent &event) override;
  void activate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
  void reset(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
  void deactivate(const fcitx::InputMethodEntry &entry, fcitx::InputContextEvent &event) override;
  std::string subModeIconImpl(const fcitx::InputMethodEntry &, fcitx::InputContext &) override;
  std::string subModeLabelImpl(const fcitx::InputMethodEntry &, fcitx::InputContext &) override;
  std::string subMode(const fcitx::InputMethodEntry &, fcitx::InputContext &) override;
  // Rereads SebType's settings (the Configurator's languages).
  void reloadConfig() override;
  // Saves learned words: Rime's sync, Mozc's.
  void save() override;
  // fcitx://config/addon/sebtype/deploy: Rime applies changed settings and data; .../mozc: Mozc starts again
  // with the files the Configurator or setup changed (its settings, dictionaries and learned words).
  void setSubConfig(const std::string &path, const fcitx::RawConfig &) override;

  fcitx::Instance *instance() { return instance_; }
  Core &core() { return *core_; }
  // Draws what the core says into ic, shows its notice and tells the tray.
  void update(fcitx::InputContext *ic);
  static std::string iconName(const std::string &icon) { return "sebtype-" + icon; }

 private:
  fcitx::InputMethodEntry entry() const;
  // Tells the core whether what is typed in ic may be learned.
  void followField(fcitx::InputContext *ic);
  // The tray and Plasma's input method panel read the icon and menu again when it changed, and while 中文 is
  // preparing they look again every half second, so the key turns back to 中 when Rime is done (#275).
  void updateStatus(fcitx::InputContext *ic);

  fcitx::Instance *instance_;
  std::unique_ptr<Core> core_;
  std::string lastIcon_;
  std::string shown_;        // the last popup by the caret (Instance::showCustomInputMethodInformation)
  uint64_t shownUntil_ = 0;  // and when Fcitx5 hides it (CLOCK_MONOTONIC, µs)
  std::unique_ptr<Service> service_;
  std::unique_ptr<fcitx::EventSourceTime> poll_;
};

}  // namespace sebtype
