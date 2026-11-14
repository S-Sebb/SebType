// SPDX-License-Identifier: LGPL-2.1-or-later
// SebType's tray item: a StatusNotifierItem with SebType's icon and menu. Ported from Fcitx5's
// notificationitem module (Copyright 2017 CSSlayer <wengxt@gmail.com>), trimmed to what SebType shows.
//
// It is loaded as Fcitx5's "notificationitem" add-on (a per-user add-on entry setup-ime.sh writes), so
// Fcitx5's classic UI, which asks that add-on whether a tray item is up, turns its own X11 tray icon off
// as it would for Fcitx5's: SebType's is the only one, and Fcitx5's own items (its settings) never show.
#pragma once

#include <fcitx-utils/dbus/bus.h>
#include <fcitx-utils/dbus/message.h>
#include <fcitx-utils/dbus/variant.h>
#include <fcitx-utils/i18n.h>
#include <fcitx-utils/dbus/objectvtable.h>
#include <fcitx-utils/dbus/servicewatcher.h>
#include <fcitx-utils/eventloopinterface.h>
#include <fcitx-utils/handlertable.h>
#include <fcitx-utils/trackableobject.h>
#include <fcitx/addoninstance.h>
#include <fcitx/instance.h>
#include <notificationitem_public.h>
#include <sebtype/types.h>

#include <memory>
#include <string>
#include <vector>

namespace sebtype {

class NotificationItem;
class SebTypeEngine;

class StatusNotifierItem : public fcitx::dbus::ObjectVTable<StatusNotifierItem> {
 public:
  explicit StatusNotifierItem(NotificationItem *parent) : parent_(parent) {}
  using Pixmaps = std::vector<fcitx::dbus::DBusStruct<int32_t, int32_t, std::vector<uint8_t>>>;
  using ToolTip = fcitx::dbus::DBusStruct<std::string, Pixmaps, std::string, std::string>;

  void scroll(int delta, const std::string &orientation);
  void activate(int, int);
  void secondaryActivate(int, int) {}
  std::string iconName();
  ToolTip toolTip();
  void notifyChanged();
  void reset() {
    releaseSlot();
    lastIcon_.clear(), lastTitle_.clear();
  }

 private:
  FCITX_OBJECT_VTABLE_METHOD(scroll, "Scroll", "is", "");
  FCITX_OBJECT_VTABLE_METHOD(activate, "Activate", "ii", "");
  FCITX_OBJECT_VTABLE_METHOD(secondaryActivate, "SecondaryActivate", "ii", "");
  FCITX_OBJECT_VTABLE_SIGNAL(newIcon, "NewIcon", "");
  FCITX_OBJECT_VTABLE_SIGNAL(newToolTip, "NewToolTip", "");
  FCITX_OBJECT_VTABLE_SIGNAL(newStatus, "NewStatus", "s");
  FCITX_OBJECT_VTABLE_SIGNAL(newTitle, "NewTitle", "");
  // Id stays Fcitx5's, so Plasma keeps the item where the user put it.
  FCITX_OBJECT_VTABLE_PROPERTY(category, "Category", "s", []() { return "SystemServices"; });
  FCITX_OBJECT_VTABLE_PROPERTY(id, "Id", "s", []() { return "Fcitx"; });
  FCITX_OBJECT_VTABLE_PROPERTY(title, "Title", "s", []() { return fcitx::translateDomain("fcitx5", "Input Method"); });
  FCITX_OBJECT_VTABLE_PROPERTY(status, "Status", "s", []() { return "Active"; });
  FCITX_OBJECT_VTABLE_PROPERTY(windowId, "WindowId", "i", []() { return 0; });
  FCITX_OBJECT_VTABLE_PROPERTY(iconNameProperty, "IconName", "s", [this]() { return iconName(); });
  FCITX_OBJECT_VTABLE_PROPERTY(iconPixmap, "IconPixmap", "a(iiay)", []() { return Pixmaps{}; });
  FCITX_OBJECT_VTABLE_PROPERTY(overlayIconName, "OverlayIconName", "s", []() { return ""; });
  FCITX_OBJECT_VTABLE_PROPERTY(overlayIconPixmap, "OverlayIconPixmap", "a(iiay)", []() { return Pixmaps{}; });
  FCITX_OBJECT_VTABLE_PROPERTY(attentionIconName, "AttentionIconName", "s", []() { return ""; });
  FCITX_OBJECT_VTABLE_PROPERTY(attentionIconPixmap, "AttentionIconPixmap", "a(iiay)", []() { return Pixmaps{}; });
  FCITX_OBJECT_VTABLE_PROPERTY(attentionMovieName, "AttentionMovieName", "s", []() { return ""; });
  FCITX_OBJECT_VTABLE_PROPERTY(toolTipProperty, "ToolTip", "(sa(iiay)ss)", [this]() { return toolTip(); });
  FCITX_OBJECT_VTABLE_PROPERTY(itemIsMenu, "ItemIsMenu", "b", []() { return false; });
  FCITX_OBJECT_VTABLE_PROPERTY(menu, "Menu", "o", []() { return fcitx::dbus::ObjectPath("/MenuBar"); });
  FCITX_OBJECT_VTABLE_PROPERTY(iconThemePath, "IconThemePath", "s", []() { return ""; });

  NotificationItem *parent_;
  int deltaAcc_ = 0;
  std::string lastIcon_, lastTitle_;
};

// The menu: SebType's (the languages, then the active one's switch), then Fcitx5's Restart and Exit.
class DBusMenu : public fcitx::dbus::ObjectVTable<DBusMenu> {
 public:
  using Property = fcitx::dbus::DictEntry<std::string, fcitx::dbus::Variant>;
  using Properties = std::vector<Property>;
  using Layout = fcitx::dbus::DBusStruct<int32_t, Properties, std::vector<fcitx::dbus::Variant>>;

  explicit DBusMenu(NotificationItem *parent) : parent_(parent) {}
  void updateMenu();
  fcitx::InputContext *lastRelevantIc();
  void reset() {
    releaseSlot();
    items_.clear();
  }

 private:
  void event(int32_t id, const std::string &type, const fcitx::dbus::Variant &, uint32_t);
  fcitx::dbus::Variant getProperty(int32_t, const std::string &);
  std::tuple<uint32_t, Layout> getLayout(int32_t parentId, int32_t depth, const std::vector<std::string> &names);
  std::vector<fcitx::dbus::DBusStruct<int32_t, Properties>> getGroupProperties(const std::vector<int32_t> &ids,
                                                                               const std::vector<std::string> &);
  bool aboutToShow(int32_t id);
  Properties properties(int32_t id);
  void handle(int32_t id);

  FCITX_OBJECT_VTABLE_PROPERTY(version, "Version", "u", []() { return 2u; });
  FCITX_OBJECT_VTABLE_PROPERTY(status, "Status", "s", []() { return "normal"; });
  FCITX_OBJECT_VTABLE_SIGNAL(layoutUpdated, "LayoutUpdated", "ui");
  FCITX_OBJECT_VTABLE_SIGNAL(itemsPropertiesUpdated, "ItemsPropertiesUpdated", "a(ia{sv})a(ias)");
  FCITX_OBJECT_VTABLE_METHOD(event, "Event", "isvu", "");
  FCITX_OBJECT_VTABLE_METHOD(getProperty, "GetProperty", "is", "v");
  FCITX_OBJECT_VTABLE_METHOD(getLayout, "GetLayout", "iias", "u(ia{sv}av)");
  FCITX_OBJECT_VTABLE_METHOD(getGroupProperties, "GetGroupProperties", "aias", "a(ia{sv})");
  FCITX_OBJECT_VTABLE_METHOD(aboutToShow, "AboutToShow", "i", "b");

  NotificationItem *parent_;
  uint32_t revision_ = 2;
  std::vector<MenuItem> items_;  // SebType's part, as last laid out
  std::unique_ptr<fcitx::EventSourceTime> clickEvent_;
  fcitx::TrackableObjectReference<fcitx::InputContext> lastRelevantIc_;
};

class NotificationItem final : public fcitx::AddonInstance {
 public:
  explicit NotificationItem(fcitx::Instance *instance);
  ~NotificationItem() override;

  fcitx::Instance *instance() { return instance_; }
  SebTypeEngine *engine();
  DBusMenu *menu() { return menu_.get(); }
  // The icon, tooltip and menu changed.
  void update();

  // What Fcitx5's classic UI asks of its notificationitem add-on.
  void enable();
  void disable();
  bool registered() const { return registered_; }
  std::unique_ptr<fcitx::HandlerTableEntry<fcitx::NotificationItemCallback>> watch(
      fcitx::NotificationItemCallback callback) {
    return handlers_.add(std::move(callback));
  }

 private:
  FCITX_ADDON_EXPORT_FUNCTION(NotificationItem, enable);
  FCITX_ADDON_EXPORT_FUNCTION(NotificationItem, disable);
  FCITX_ADDON_EXPORT_FUNCTION(NotificationItem, watch);
  FCITX_ADDON_EXPORT_FUNCTION(NotificationItem, registered);

  fcitx::dbus::Bus *bus();
  void setWatcher(const std::string &name);
  void setRegistered(bool registered);
  void scheduleRegister();
  void registerItem();
  void cleanUp();

  fcitx::Instance *instance_;
  std::unique_ptr<fcitx::dbus::ServiceWatcher> watcher_;
  std::unique_ptr<fcitx::dbus::ServiceWatcherEntry> watcherEntry_;
  std::unique_ptr<fcitx::dbus::Bus> privateBus_;
  std::unique_ptr<StatusNotifierItem> sni_;
  std::unique_ptr<DBusMenu> menu_;
  std::unique_ptr<fcitx::dbus::Slot> pendingRegister_;
  std::unique_ptr<fcitx::EventSourceTime> registerTimer_;
  std::string watcherName_;
  int enabled_ = 0;
  bool registered_ = false;
  fcitx::HandlerTable<fcitx::NotificationItemCallback> handlers_;
  fcitx::TrackableObject<void> lifeTime_;
};

}  // namespace sebtype
