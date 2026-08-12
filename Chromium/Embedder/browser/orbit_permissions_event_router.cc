// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_permissions_event_router.h"

#include <memory>
#include <utility>

#include "base/values.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/event_dispatcher.mojom.h"
#include "extensions/common/permissions/permission_set.h"
#include "orbit/browser/api/permissions/orbit_permissions_api.h"

namespace orbit {

// static
OrbitPermissionsEventRouter& OrbitPermissionsEventRouter::GetInstance() {
  static base::NoDestructor<OrbitPermissionsEventRouter> instance;
  return *instance;
}

OrbitPermissionsEventRouter::OrbitPermissionsEventRouter() = default;
OrbitPermissionsEventRouter::~OrbitPermissionsEventRouter() = default;

void OrbitPermissionsEventRouter::StartObserving(
    content::BrowserContext* browser_context) {
  if (!browser_context || permissions_manager_observation_.IsObserving()) {
    return;
  }
  extensions::PermissionsManager* manager =
      extensions::PermissionsManager::Get(browser_context);
  if (!manager) {
    return;
  }
  browser_context_ = browser_context;
  permissions_manager_observation_.Observe(manager);
}

void OrbitPermissionsEventRouter::StopObserving() {
  permissions_manager_observation_.Reset();
  browser_context_ = nullptr;
}

void OrbitPermissionsEventRouter::OnExtensionPermissionsUpdated(
    const extensions::Extension& extension,
    const extensions::PermissionSet& permissions,
    extensions::PermissionsManager::UpdateReason reason) {
  extensions::events::HistogramValue histogram_value =
      extensions::events::UNKNOWN;
  const char* event_name = nullptr;
  switch (reason) {
    case extensions::PermissionsManager::UpdateReason::kAdded:
      histogram_value = extensions::events::PERMISSIONS_ON_ADDED;
      event_name = "permissions.onAdded";
      break;
    case extensions::PermissionsManager::UpdateReason::kRemoved:
      histogram_value = extensions::events::PERMISSIONS_ON_REMOVED;
      event_name = "permissions.onRemoved";
      break;
    case extensions::PermissionsManager::UpdateReason::kPolicy:
      return;
  }

  extensions::EventRouter* event_router =
      browser_context_ ? extensions::EventRouter::Get(browser_context_)
                       : nullptr;
  if (!event_router) {
    return;
  }

  base::ListValue event_args;
  event_args.Append(PackPermissionSet(permissions));
  event_router->DispatchEventToExtension(
      extension.id(),
      std::make_unique<extensions::Event>(histogram_value, event_name,
                                          std::move(event_args),
                                          browser_context_));
}

}  // namespace orbit
