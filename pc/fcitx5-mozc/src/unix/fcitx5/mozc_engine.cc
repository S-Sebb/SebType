/*
 * Copyright (C) 2017~2017 by CSSlayer
 * wengxt@gmail.com
 *
 * This library is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as
 * published by the Free Software Foundation; either version 2 of the
 * License, or (at your option) any later version.
 *
 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; see the file COPYING. If not,
 * see <http://www.gnu.org/licenses/>.
 */

#include "unix/fcitx5/mozc_engine.h"

#include <fcitx-config/iniparser.h>
#include <fcitx-config/rawconfig.h>
#include <fcitx-utils/log.h>
#include <fcitx-utils/macros.h>
#include <fcitx-utils/standardpath.h>
#include <fcitx-utils/stringutils.h>
#include <fcitx/action.h>
#include <fcitx/addoninstance.h>
#include <fcitx/event.h>
#include <fcitx/inputcontext.h>
#include <fcitx/inputcontextmanager.h>
#include <fcitx/inputmethodmanager.h>
#include <fcitx/instance.h>
#include <fcitx/statusarea.h>
#include <fcitx/userinterface.h>
#include <fcitx/userinterfacemanager.h>

#include <cstddef>
#include <memory>
#include <string>

#include "base/init_mozc.h"
#include "protocol/commands.pb.h"
#include "unix/fcitx5/i18nwrapper.h"
#include "unix/fcitx5/mozc_client_interface.h"
#include "unix/fcitx5/mozc_client_pool.h"
#include "unix/fcitx5/mozc_response_parser.h"
#include "unix/fcitx5/mozc_state.h"

namespace fcitx {

const struct CompositionModeInfo {
  const char *name;
  const char *icon;
  const char *label;
  const char *description;
  mozc::commands::CompositionMode mode;
} kPropCompositionModes[] = {
    {
        "mozc-mode-direct",
        "fcitx_mozc_direct",
        "A",
        N_("Direct"),
        mozc::commands::DIRECT,
    },
    {
        "mozc-mode-hiragana",
        "fcitx_mozc_hiragana",
        "\xe3\x81\x82",  // Hiragana letter A in UTF-8.
        N_("Hiragana"),
        mozc::commands::HIRAGANA,
    },
    {
        "mozc-mode-katakana_full",
        "fcitx_mozc_katakana_full",
        "\xe3\x82\xa2",  // Katakana letter A.
        N_("Full Katakana"),
        mozc::commands::FULL_KATAKANA,
    },
    {

        "mozc-mode-alpha_half",
        "fcitx_mozc_alpha_half",
        "A",
        N_("Half ASCII"),
        mozc::commands::HALF_ASCII,
    },
    {

        "mozc-mode-alpha_full",
        "fcitx_mozc_alpha_full",
        "\xef\xbc\xa1",  // Full width ASCII letter A.
        N_("Full ASCII"),
        mozc::commands::FULL_ASCII,
    },
    {
        "mozc-mode-katakana_half",
        "fcitx_mozc_katakana_half",
        "\xef\xbd\xb1",  // Half width Katakana letter A.
        N_("Half Katakana"),
        mozc::commands::HALF_KATAKANA,
    },
};
const size_t kNumCompositionModes = FCITX_ARRAY_SIZE(kPropCompositionModes);

std::string MozcKanaAction::shortText(InputContext *ic) const {
  return katakana(ic) ? "ア → あ\tAlt+`" : "あ → ア\tAlt+`";
}

void MozcKanaAction::activate(InputContext *ic) {
  engine_->mozcState(ic)->SendCompositionMode(
      katakana(ic) ? mozc::commands::HIRAGANA : mozc::commands::FULL_KATAKANA);
}

bool MozcKanaAction::katakana(InputContext *ic) const {
  const auto mode = engine_->mozcState(ic)->GetCompositionMode();
  return mode == mozc::commands::FULL_KATAKANA ||
         mode == mozc::commands::HALF_KATAKANA;
}

// This array must correspond with the CompositionMode enum in the
// mozc/session/command.proto file.
static_assert(mozc::commands::NUM_OF_COMPOSITIONS == kNumCompositionModes,
              "number of modes must match");

Instance *Init(Instance *instance) {
  int argc = 1;
  char argv0[] = "fcitx_mozc";
  char *_argv[] = {argv0};
  char **argv = _argv;
  mozc::InitMozc(argv[0], &argc, &argv);
  return instance;
}

MozcEngine::MozcEngine(Instance *instance)
    : instance_(Init(instance)),
      parser_(std::make_unique<MozcResponseParser>(this)),
      client_(createClient()),
      factory_([this](InputContext &ic) { return new MozcState(&ic, this); }) {
  pool_ = std::make_unique<MozcClientPool>(GetSharedStatePolicy());
  instance_->inputContextManager().registerProperty("mozcState", &factory_);
  instance_->userInterfaceManager().registerAction("mozc-kana", &kanaAction_);

  globalConfigReloadHandle_ =
      instance_->watchEvent(EventType::GlobalConfigReloaded,
                            EventWatcherPhase::Default, [this](Event &) {
                              ResetClientPool();
                              return true;
                            });

  // SebType: redraw the tray when Caps Lock toggles, so English mode can show
  // its Caps Lock icon (as fcitx5-rime does for fcitx_rime_latin_upper).
  xkbStateChangedConnection_ = instance_->connect<Instance::XkbStateMaskChanged>(
      [this](const std::string &display, auto oldMask, auto newMask) {
        auto capsLock = [](const auto &mask) {
          return mask && KeyStates(std::get<2>(*mask)).test(KeyState::CapsLock);
        };
        if (capsLock(oldMask) == capsLock(newMask)) {
          return;
        }
        instance_->inputContextManager().foreachFocused(
            [this, &display](InputContext *ic) {
              if (ic->display() == display &&
                  instance_->inputMethod(ic) == "mozc") {
                ic->updateUserInterface(UserInterfaceComponent::StatusArea);
              }
              return true;
            });
      });

  reloadConfig();
}

MozcEngine::~MozcEngine() {}

void MozcEngine::setConfig(const RawConfig &config) {
  config_.load(config, true);
  safeSaveAsIni(config_, "conf/mozc.conf");
  ResetClientPool();
}

void MozcEngine::reloadConfig() {
  readAsIni(config_, "conf/mozc.conf");
  ResetClientPool();
}
void MozcEngine::activate(const fcitx::InputMethodEntry & /*entry*/,
                          fcitx::InputContextEvent &event) {
  if (client_) {
    client_->EnsureConnection();
  }
  auto *ic = event.inputContext();
  auto *mozc_state = mozcState(ic);
  mozc_state->FocusIn();
  ic->statusArea().addAction(StatusGroup::InputMethod, &kanaAction_);
}
void MozcEngine::deactivate(const fcitx::InputMethodEntry & /*entry*/,
                            fcitx::InputContextEvent &event) {
  auto *ic = event.inputContext();
  deactivating_ = true;
  auto *mozc_state = mozcState(ic);
  mozc_state->FocusOut(event);
  deactivating_ = false;
}
void MozcEngine::keyEvent(const InputMethodEntry &entry, KeyEvent &event) {
  auto *mozc_state = mozcState(event.inputContext());

  const auto &group = instance_->inputMethodManager().currentGroup();
  std::string layout = group.layoutFor(entry.uniqueName());
  if (layout.empty()) {
    layout = group.defaultLayout();
  }

  const bool isJP = (layout == "jp" || stringutils::startsWith(layout, "jp-"));

  if (mozc_state->ProcessKeyEvent(event.rawKey().sym(), event.rawKey().code(),
                                  event.rawKey().states(), isJP,
                                  event.isRelease())) {
    event.filterAndAccept();
  }
}

void MozcEngine::reset(const InputMethodEntry & /*entry*/,
                       InputContextEvent &event) {
  auto *mozc_state = mozcState(event.inputContext());
  mozc_state->Reset();
}

void MozcEngine::save() {
  if (client_ == nullptr) {
    return;
  }
  client_->SyncData();
}

std::string MozcEngine::subMode(const fcitx::InputMethodEntry & /*entry*/,
                                fcitx::InputContext &ic) {
  auto *mozc_state = mozcState(&ic);
  return _(kPropCompositionModes[mozc_state->GetCompositionMode()].description);
}

std::string MozcEngine::subModeIconImpl(
    const fcitx::InputMethodEntry & /*unused*/, fcitx::InputContext &ic) {
  auto *mozc_state = mozcState(&ic);
  const auto mode = mozc_state->GetCompositionMode();
  std::string icon = _(kPropCompositionModes[mode].icon);
  // SebType: the English modes have a Caps Lock icon, e.g.
  // fcitx_mozc_direct_upper.
  if (mode == mozc::commands::DIRECT || mode == mozc::commands::HALF_ASCII ||
      mode == mozc::commands::FULL_ASCII) {
    if (auto mask = instance_->xkbStateMask(ic.display());
        mask && KeyStates(std::get<2>(*mask)).test(KeyState::CapsLock)) {
      icon += "_upper";
    }
  }
  return icon;
}

MozcState *MozcEngine::mozcState(InputContext *ic) {
  return ic->propertyFor(&factory_);
}

void MozcEngine::compositionModeUpdated(InputContext *ic) {
  kanaAction_.update(ic);
  ic->updateUserInterface(UserInterfaceComponent::StatusArea);
}

AddonInstance *MozcEngine::clipboardAddon() { return clipboard(); }

void MozcEngine::ResetClientPool() {
  if (pool_->policy() != GetSharedStatePolicy()) {
    instance_->inputContextManager().foreach ([this](InputContext *ic) {
      if (auto *state = this->mozcState(ic)) {
        state->ReleaseClient();
      }
      return true;
    });
    pool_->setPolicy(GetSharedStatePolicy());
  }
}

PropertyPropagatePolicy MozcEngine::GetSharedStatePolicy() {
  switch (*config_.sharedStatePolicy) {
    case SharedStatePolicy::All:
      return PropertyPropagatePolicy::All;
    case SharedStatePolicy::Program:
      return PropertyPropagatePolicy::Program;
    case SharedStatePolicy::No:
      return PropertyPropagatePolicy::No;
    case SharedStatePolicy::FollowGlobalConfig:
    default:
      return instance_->globalConfig().shareInputState();
  }
}

}  // namespace fcitx
