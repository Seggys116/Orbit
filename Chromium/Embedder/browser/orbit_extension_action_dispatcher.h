// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Serialises extensions::ExtensionAction state and hands it to Swift, which
// owns every pixel of Orbit's toolbar. Payload carries both `defaults`
// (every tab) and `tabs` (only tabs with an override).

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_ACTION_DISPATCHER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_ACTION_DISPATCHER_H_

#include <stdint.h>

#include <string>

#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "orbit/bridge/orbit_bridge_api.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace extensions {
class Extension;
class ExtensionAction;
}  // namespace extensions

namespace orbit {

class OrbitExtensionActionDispatcher
    : public extensions::ExtensionRegistryObserver {
 public:
  static OrbitExtensionActionDispatcher& GetInstance();

  OrbitExtensionActionDispatcher(const OrbitExtensionActionDispatcher&) = delete;
  OrbitExtensionActionDispatcher& operator=(
      const OrbitExtensionActionDispatcher&) = delete;

  void SetCallback(OrbitExtensionActionCallback callback, void* opaque);

  // Called once the single OrbitBrowserContext exists, and again (with
  // StopObserving) as it goes away -- see OrbitBrowserMainParts.
  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();

  // Relays `extension`'s whole current action state; called after every
  // chrome.action mutation and whenever //extensions loads/unloads it.
  void NotifyChange(content::BrowserContext* browser_context,
                    const extensions::Extension* extension);

  // One NotifyChange-shaped object per loaded extension with an action.
  // Swift reads this once ready, so an early badge set is never lost.
  std::string GetAllActionsJSON(content::BrowserContext* browser_context);

  // Drops every per-tab override for `tab_id` and relays the result, so a
  // reused tab id cannot inherit a badge (mirrors Chrome's tab-close behaviour).
  void ClearTabState(content::BrowserContext* browser_context, int32_t tab_id);

 private:
  friend class base::NoDestructor<OrbitExtensionActionDispatcher>;

  OrbitExtensionActionDispatcher();
  ~OrbitExtensionActionDispatcher() override;

  // extensions::ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext* browser_context,
                         const extensions::Extension* extension) override;
  void OnExtensionUnloaded(content::BrowserContext* browser_context,
                           const extensions::Extension* extension,
                           extensions::UnloadedExtensionReason reason) override;

  // The installed callback lives in a file-scope static in the .cc, matching
  // orbit_bridge_api.cc's handling of Swift-installed callback pointers.
  void Emit(const std::string& json);

  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      registry_observation_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_ACTION_DISPATCHER_H_
