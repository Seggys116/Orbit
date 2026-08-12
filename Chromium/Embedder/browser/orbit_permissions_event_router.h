// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.permissions.onAdded/onRemoved via extensions::PermissionsManager's observer;
// fires for every grant/revocation, not just chrome.permissions.request/remove calls.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSIONS_EVENT_ROUTER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSIONS_EVENT_ROUTER_H_

#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "extensions/browser/permissions_manager.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

class OrbitPermissionsEventRouter
    : public extensions::PermissionsManager::Observer {
 public:
  static OrbitPermissionsEventRouter& GetInstance();

  OrbitPermissionsEventRouter(const OrbitPermissionsEventRouter&) = delete;
  OrbitPermissionsEventRouter& operator=(const OrbitPermissionsEventRouter&) =
      delete;

  // Called once the single OrbitBrowserContext exists, and again (with
  // StopObserving) as it goes away -- see OrbitBrowserMainParts.
  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();

  // extensions::PermissionsManager::Observer:
  void OnExtensionPermissionsUpdated(
      const extensions::Extension& extension,
      const extensions::PermissionSet& permissions,
      extensions::PermissionsManager::UpdateReason reason) override;

 private:
  friend class base::NoDestructor<OrbitPermissionsEventRouter>;

  OrbitPermissionsEventRouter();
  ~OrbitPermissionsEventRouter() override;

  raw_ptr<content::BrowserContext> browser_context_ = nullptr;
  base::ScopedObservation<extensions::PermissionsManager,
                          extensions::PermissionsManager::Observer>
      permissions_manager_observation_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSIONS_EVENT_ROUTER_H_
