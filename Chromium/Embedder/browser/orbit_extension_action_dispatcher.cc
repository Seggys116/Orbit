// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_action_dispatcher.h"

#include <optional>
#include <vector>

#include "base/base64.h"
#include "base/containers/span.h"
#include "base/json/json_writer.h"
#include "base/strings/stringprintf.h"
#include "base/values.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/codec/png_codec.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_rep.h"

namespace orbit {

namespace {

OrbitExtensionActionCallback g_action_callback = nullptr;
void* g_action_opaque = nullptr;

std::string ColorToHexRGBA(SkColor color) {
  return base::StringPrintf("#%02X%02X%02X%02X", SkColorGetR(color),
                            SkColorGetG(color), SkColorGetB(color),
                            SkColorGetA(color));
}

// PNG bytes of an icon set via chrome.action.setIcon, "" if none. Not the
// manifest's declared icon: Swift already reads that off disk itself.
std::string ExplicitlySetIconBase64(const extensions::ExtensionAction& action,
                                    int tab_id) {
  gfx::Image icon = action.GetExplicitlySetIcon(tab_id);
  if (icon.IsEmpty()) {
    return std::string();
  }
  // Densest representation supplied, not AsBitmap()'s 1x one: Swift draws
  // this into a fixed toolbar slot on Retina, where 1x is visibly soft.
  SkBitmap bitmap = icon.AsBitmap();
  for (const gfx::ImageSkiaRep& rep : icon.AsImageSkia().image_reps()) {
    if (rep.GetBitmap().width() > bitmap.width()) {
      bitmap = rep.GetBitmap();
    }
  }
  std::optional<std::vector<uint8_t>> png =
      gfx::PNGCodec::EncodeBGRASkBitmap(bitmap,
                                        /*discard_transparency=*/false);
  if (!png.has_value()) {
    return std::string();
  }
  return base::Base64Encode(base::span<const uint8_t>(*png));
}

base::DictValue StateForTab(const extensions::ExtensionAction& action,
                            int tab_id) {
  base::DictValue state;
  state.Set("badgeText", action.GetDisplayBadgeText(tab_id));
  state.Set("badgeBackgroundColor",
            ColorToHexRGBA(action.GetBadgeBackgroundColor(tab_id)));
  state.Set("badgeTextColor",
            ColorToHexRGBA(action.GetBadgeTextColor(tab_id)));
  state.Set("title", action.GetTitle(tab_id));
  state.Set("isEnabled", action.GetIsVisibleIgnoringDeclarative(tab_id));
  state.Set("popupUrl", action.GetPopupUrl(tab_id).spec());
  const std::string icon = ExplicitlySetIconBase64(action, tab_id);
  if (!icon.empty()) {
    state.Set("iconPNG", icon);
  }
  return state;
}

// True if this tab carries any value of its own; without this every tab
// would get the default state copied in, hiding later changes to the default.
bool TabHasOwnState(const extensions::ExtensionAction& action, int tab_id) {
  return action.HasBadgeText(tab_id) || action.HasBadgeBackgroundColor(tab_id) ||
         action.HasBadgeTextColor(tab_id) || action.HasTitle(tab_id) ||
         action.HasIsVisible(tab_id) || action.HasIcon(tab_id) ||
         action.HasPopupUrl(tab_id) || action.HasDNRActionCount(tab_id);
}

base::DictValue ActionToDict(const extensions::Extension& extension,
                             const extensions::ExtensionAction& action) {
  base::DictValue dict;
  dict.Set("extensionId", extension.id());
  dict.Set("defaults", StateForTab(action, extensions::ExtensionAction::kDefaultTabId));

  base::ListValue tabs;
  for (const OrbitTabInfo* tab : OrbitTabRegistry::GetInstance().GetAllTabs()) {
    if (!TabHasOwnState(action, tab->id)) {
      continue;
    }
    base::DictValue tab_state = StateForTab(action, tab->id);
    tab_state.Set("tabId", tab->id);
    tabs.Append(std::move(tab_state));
  }
  dict.Set("tabs", std::move(tabs));
  return dict;
}

std::string DictToJSON(const base::DictValue& dict) {
  std::string json;
  base::JSONWriter::Write(dict, &json);
  return json;
}

extensions::ExtensionAction* ActionFor(content::BrowserContext* browser_context,
                                       const extensions::Extension& extension) {
  extensions::ExtensionActionManager* manager =
      extensions::ExtensionActionManager::Get(browser_context);
  return manager ? manager->GetExtensionAction(extension) : nullptr;
}

}  // namespace

// static
OrbitExtensionActionDispatcher& OrbitExtensionActionDispatcher::GetInstance() {
  static base::NoDestructor<OrbitExtensionActionDispatcher> instance;
  return *instance;
}

OrbitExtensionActionDispatcher::OrbitExtensionActionDispatcher() = default;
OrbitExtensionActionDispatcher::~OrbitExtensionActionDispatcher() = default;

void OrbitExtensionActionDispatcher::SetCallback(
    OrbitExtensionActionCallback callback, void* opaque) {
  g_action_callback = callback;
  g_action_opaque = opaque;
}

void OrbitExtensionActionDispatcher::StartObserving(
    content::BrowserContext* browser_context) {
  if (!browser_context || registry_observation_.IsObserving()) {
    return;
  }
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(browser_context);
  if (registry) {
    registry_observation_.Observe(registry);
  }
}

void OrbitExtensionActionDispatcher::StopObserving() {
  registry_observation_.Reset();
}

void OrbitExtensionActionDispatcher::NotifyChange(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension) {
  if (!browser_context || !extension) {
    return;
  }
  extensions::ExtensionAction* action = ActionFor(browser_context, *extension);
  if (!action) {
    return;
  }
  Emit(DictToJSON(ActionToDict(*extension, *action)));
}

std::string OrbitExtensionActionDispatcher::GetAllActionsJSON(
    content::BrowserContext* browser_context) {
  base::ListValue list;
  if (browser_context) {
    extensions::ExtensionRegistry* registry =
        extensions::ExtensionRegistry::Get(browser_context);
    if (registry) {
      for (const auto& extension : registry->enabled_extensions()) {
        if (extensions::ExtensionAction* action =
                ActionFor(browser_context, *extension)) {
          list.Append(ActionToDict(*extension, *action));
        }
      }
    }
  }
  std::string json;
  base::JSONWriter::Write(list, &json);
  return json;
}

void OrbitExtensionActionDispatcher::ClearTabState(
    content::BrowserContext* browser_context, int32_t tab_id) {
  if (!browser_context) {
    return;
  }
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(browser_context);
  if (!registry) {
    return;
  }
  for (const auto& extension : registry->enabled_extensions()) {
    extensions::ExtensionAction* action = ActionFor(browser_context, *extension);
    if (!action || !TabHasOwnState(*action, tab_id)) {
      continue;
    }
    action->ClearAllValuesForTab(tab_id);
    action->ClearDeclarativeValuesForTab(tab_id);
    Emit(DictToJSON(ActionToDict(*extension, *action)));
  }
}

void OrbitExtensionActionDispatcher::OnExtensionLoaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension) {
  NotifyChange(browser_context, extension);
}

void OrbitExtensionActionDispatcher::OnExtensionUnloaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    extensions::UnloadedExtensionReason reason) {
  if (!extension) {
    return;
  }
  // The ExtensionAction is destroyed with the extension; empty defaults plus
  // no tabs is what "no action" looks like on the wire.
  base::DictValue dict;
  dict.Set("extensionId", extension->id());
  dict.Set("defaults", base::DictValue());
  dict.Set("tabs", base::ListValue());
  Emit(DictToJSON(dict));
}

void OrbitExtensionActionDispatcher::Emit(const std::string& json) {
  if (g_action_callback) {
    g_action_callback(g_action_opaque, json.c_str());
  }
}

}  // namespace orbit
