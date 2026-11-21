// SPDX-License-Identifier: LGPL-2.1-or-later
// SebType's tray item, ported from Fcitx5's notificationitem module (Copyright 2017 CSSlayer
// <wengxt@gmail.com>): see tray.h.
#include "tray.h"

#include <cairo.h>
#include <fcitx-utils/dbus/message.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/standardpaths.h>
#include <fcitx/addonmanager.h>
#include <fcitx/inputcontext.h>

#include <filesystem>

#include "dbus_public.h"
#include "sebtype.h"

namespace sebtype {

namespace {
constexpr const char *kWatcher = "org.kde.StatusNotifierWatcher";
// Menu ids: SebType's items from kFirst on, Fcitx5's own below it.
enum : int32_t { kRoot = 0, kSeparator = 1, kRestart = 2, kExit = 3, kFirst = 100 };
}  // namespace

// --- The item ---

void StatusNotifierItem::scroll(int delta, const std::string &orientation) {
  if (orientation != "vertical" && orientation != "Vertical") return;
  auto *engine = parent_->engine();
  if (!engine) return;
  // Scrolling steps through the languages, as Fcitx5's tray stepped through its input methods.
  deltaAcc_ += delta;
  while (deltaAcc_ >= 120 || deltaAcc_ <= -120) {
    const bool forward = deltaAcc_ > 0;
    deltaAcc_ += forward ? -120 : 120;
    const auto &on = engine->core().settings().languages;
    auto it = std::find(on.begin(), on.end(), engine->core().language());
    size_t i = it == on.end() ? 0 : it - on.begin();
    i = forward ? (i + 1) % on.size() : (i + on.size() - 1) % on.size();
    engine->core().selectLanguage(on[i]);
    engine->update(parent_->menu()->lastRelevantIc());
  }
}

// A click on the icon is Win+Space.
void StatusNotifierItem::activate(int, int) {
  if (auto *engine = parent_->engine()) {
    engine->core().toggleLanguage();
    engine->update(parent_->menu()->lastRelevantIc());
  }
}

std::string StatusNotifierItem::icon() {
  auto *engine = parent_->engine();
  return engine ? engine->core().icon() : "en";
}

// Every size pc/icons draws, each at its own pixels (#275). A tray asks for its icon size times the screen's
// scale (28 px for 22 at 125 %) and takes the pixmap of that size as it is. By name, KIconLoader rounds the
// scale up and shrank hicolor's 22x22@2 (44 px) to 28 px, which blurred it (#441).
StatusNotifierItem::Pixmaps StatusNotifierItem::iconPixmap() {
  const std::string state = icon();
  if (auto it = pixmaps_.find(state); it != pixmaps_.end()) return it->second;
  Pixmaps &out = pixmaps_[state];
  std::error_code ec;
  const auto tray = fcitx::StandardPaths::global().locate(fcitx::StandardPathsType::Data, "sebtype/tray");
  for (const auto &dir : std::filesystem::directory_iterator(tray, ec)) {
    cairo_surface_t *png = cairo_image_surface_create_from_png((dir.path() / (state + ".png")).c_str());
    if (cairo_surface_status(png) == CAIRO_STATUS_SUCCESS) {
      const int w = cairo_image_surface_get_width(png), h = cairo_image_surface_get_height(png);
      const int stride = cairo_image_surface_get_stride(png);
      const unsigned char *data = cairo_image_surface_get_data(png);
      // Cairo's pixels are premultiplied native-endian words; the item's are straight ARGB, big-endian.
      std::vector<uint8_t> argb;
      argb.reserve(w * h * 4);
      for (int y = 0; y < h; ++y) {
        for (int x = 0; x < w; ++x) {
          const uint32_t p = reinterpret_cast<const uint32_t *>(data + y * stride)[x];
          const uint32_t a = p >> 24;
          auto straight = [a](uint32_t c) { return static_cast<uint8_t>(a ? (c * 255 + a / 2) / a : 0); };
          argb.insert(argb.end(), {static_cast<uint8_t>(a), straight(p >> 16 & 0xff), straight(p >> 8 & 0xff),
                                   straight(p & 0xff)});
        }
      }
      out.emplace_back(w, h, std::move(argb));
    }
    cairo_surface_destroy(png);
  }
  return out;
}

StatusNotifierItem::ToolTip StatusNotifierItem::toolTip() {
  auto *engine = parent_->engine();
  std::string title = engine ? langName(engine->core().language())
                             : fcitx::translateDomain("fcitx5", "Input Method");
  return {SebTypeEngine::iconName(icon()), Pixmaps{}, std::move(title), std::string()};
}

void StatusNotifierItem::notifyChanged() {
  if (!isRegistered()) return;
  if (auto state = icon(); state != lastIcon_) {
    newIcon();
    lastIcon_ = std::move(state);
  }
  if (auto title = std::get<2>(toolTip()); title != lastTitle_) {
    newToolTip();
    lastTitle_ = std::move(title);
  }
}

// --- The menu ---

fcitx::InputContext *DBusMenu::lastRelevantIc() {
  if (auto *ic = lastRelevantIc_.get()) return ic;
  return parent_->instance()->mostRecentInputContext();
}

void DBusMenu::updateMenu() {
  if (!isRegistered()) return;
  layoutUpdated(++revision_, kRoot);
}

void DBusMenu::event(int32_t id, const std::string &type, const fcitx::dbus::Variant &, uint32_t) {
  if (id == kRoot && type == "closed") lastRelevantIc_.unwatch();
  if (type != "clicked") return;
  // Later, so the text field has its focus back when the switch happens.
  clickEvent_ = parent_->instance()->eventLoop().addTimeEvent(
      CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + 30000, 0, [this, id](fcitx::EventSourceTime *, uint64_t) {
        handle(id);
        clickEvent_.reset();
        return true;
      });
}

void DBusMenu::handle(int32_t id) {
  if (id == kRestart) return parent_->instance()->restart();
  if (id == kExit) return parent_->instance()->exit();
  auto *engine = parent_->engine();
  const size_t i = id - kFirst;
  if (!engine || id < kFirst || i >= items_.size()) return;
  engine->core().activate(items_[i]);
  engine->update(lastRelevantIc());
}

fcitx::dbus::Variant DBusMenu::getProperty(int32_t, const std::string &) {
  throw fcitx::dbus::MethodCallError("org.freedesktop.DBus.Error.NotSupported", "NotSupported");
}

DBusMenu::Properties DBusMenu::properties(int32_t id) {
  Properties p;
  auto add = [&](const char *name, fcitx::dbus::Variant v) { p.emplace_back(name, std::move(v)); };
  if (id == kRoot) {
    add("children-display", fcitx::dbus::Variant("submenu"));
  } else if (id == kSeparator) {
    add("type", fcitx::dbus::Variant("separator"));
  } else if (id == kRestart) {
    add("label", fcitx::dbus::Variant(fcitx::translateDomain("fcitx5", "Restart")));
    add("icon-name", fcitx::dbus::Variant("view-refresh"));
  } else if (id == kExit) {
    add("label", fcitx::dbus::Variant(fcitx::translateDomain("fcitx5", "Exit")));
    add("icon-name", fcitx::dbus::Variant("application-exit"));
  } else if (id >= kFirst && static_cast<size_t>(id - kFirst) < items_.size()) {
    const MenuItem &item = items_[id - kFirst];
    if (item.kind == MenuItem::Separator) {
      add("type", fcitx::dbus::Variant("separator"));
    } else {
      add("label", fcitx::dbus::Variant(item.label));
      if (item.kind == MenuItem::Language) {
        add("icon-name", fcitx::dbus::Variant(SebTypeEngine::iconName(item.icon)));
        add("toggle-type", fcitx::dbus::Variant("radio"));
        add("toggle-state", fcitx::dbus::Variant(item.checked ? 1 : 0));
      }
    }
  }
  return p;
}

std::tuple<uint32_t, DBusMenu::Layout> DBusMenu::getLayout(int32_t parentId, int32_t depth,
                                                           const std::vector<std::string> &) {
  Layout layout;
  std::get<0>(layout) = parentId;
  std::get<1>(layout) = properties(parentId);
  if (parentId == kRoot && depth != 0) {
    auto *engine = parent_->engine();
    items_ = engine ? engine->core().menu() : std::vector<MenuItem>{};
    std::vector<int32_t> ids;
    for (size_t i = 0; i < items_.size(); ++i) ids.push_back(kFirst + static_cast<int32_t>(i));
    if (parent_->instance()->canRestart()) ids.insert(ids.end(), {kRestart, kExit});
    for (int32_t id : ids) {
      Layout child;
      std::get<0>(child) = id;
      std::get<1>(child) = properties(id);
      std::get<2>(layout).emplace_back(std::move(child));
    }
  }
  return {revision_, std::move(layout)};
}

std::vector<fcitx::dbus::DBusStruct<int32_t, DBusMenu::Properties>> DBusMenu::getGroupProperties(
    const std::vector<int32_t> &ids, const std::vector<std::string> &) {
  std::vector<fcitx::dbus::DBusStruct<int32_t, Properties>> result;
  for (int32_t id : ids) result.emplace_back(id, properties(id));
  return result;
}

bool DBusMenu::aboutToShow(int32_t id) {
  if (id == kRoot) {
    if (auto *ic = parent_->instance()->mostRecentInputContext()) lastRelevantIc_ = ic->watch();
  }
  return id == kRoot;
}

// --- The add-on ---

NotificationItem::NotificationItem(fcitx::Instance *instance)
    : instance_(instance),
      sni_(std::make_unique<StatusNotifierItem>(this)),
      menu_(std::make_unique<DBusMenu>(this)) {
  watcher_ = std::make_unique<fcitx::dbus::ServiceWatcher>(*bus());
  watcherEntry_ = watcher_->watchService(
      kWatcher, [this](const std::string &, const std::string &, const std::string &owner) { setWatcher(owner); });
}

NotificationItem::~NotificationItem() = default;

fcitx::dbus::Bus *NotificationItem::bus() {
  return instance_->addonManager().addon("dbus")->call<fcitx::IDBusModule::bus>();
}

SebTypeEngine *NotificationItem::engine() {
  return dynamic_cast<SebTypeEngine *>(instance_->addonManager().addon("sebtype", true));
}

void NotificationItem::update() {
  if (!registered_) return;
  menu_->updateMenu();
  sni_->notifyChanged();
}

void NotificationItem::setWatcher(const std::string &name) {
  watcherName_ = name;
  setRegistered(false);
  scheduleRegister();
}

void NotificationItem::setRegistered(bool registered) {
  if (!registered) cleanUp();
  if (registered_ == registered) return;
  registered_ = registered;
  for (auto &handler : handlers_.view()) handler(registered_);
}

void NotificationItem::scheduleRegister() {
  if (!enabled_ || watcherName_.empty() || registered_) return;
  // A moment later: the watcher that just came up may not be ready for calls yet.
  registerTimer_ = instance_->eventLoop().addTimeEvent(CLOCK_MONOTONIC, fcitx::now(CLOCK_MONOTONIC) + 300000, 0,
                                                       [this](fcitx::EventSourceTime *, uint64_t) {
                                                         registerItem();
                                                         return true;
                                                       });
}

// The item lives on a bus connection of its own, whose unique name is what the watcher registers.
void NotificationItem::registerItem() {
  if (!enabled_ || watcherName_.empty() || registered_) return;
  setRegistered(false);
  try {
    privateBus_ = std::make_unique<fcitx::dbus::Bus>(bus()->address());
  } catch (...) {
    return;
  }
  privateBus_->attachEventLoop(&instance_->eventLoop());
  privateBus_->addObjectVTable("/StatusNotifierItem", "org.kde.StatusNotifierItem", *sni_);
  privateBus_->addObjectVTable("/MenuBar", "com.canonical.dbusmenu", *menu_);
  auto call = privateBus_->createMethodCall(watcherName_.c_str(), "/StatusNotifierWatcher", kWatcher,
                                            "RegisterStatusNotifierItem");
  call << privateBus_->uniqueName();
  pendingRegister_ = call.callAsync(0, [this](fcitx::dbus::Message &reply) {
    auto keep = std::move(pendingRegister_);
    setRegistered(!reply.isError());
    return true;
  });
  privateBus_->flush();
}

void NotificationItem::enable() {
  if (++enabled_ == 1) scheduleRegister();
}

void NotificationItem::disable() {
  instance_->eventDispatcher().scheduleWithContext(lifeTime_.watch(), [this]() {
    if (enabled_ > 0 && --enabled_ == 0) setRegistered(false);
  });
}

void NotificationItem::cleanUp() {
  pendingRegister_.reset();
  sni_->reset();
  menu_->reset();
  privateBus_.reset();
}

class NotificationItemFactory : public fcitx::AddonFactory {
  fcitx::AddonInstance *create(fcitx::AddonManager *manager) override {
    return new NotificationItem(manager->instance());
  }
};

}  // namespace sebtype

FCITX_ADDON_FACTORY_V2(notificationitem, sebtype::NotificationItemFactory)
