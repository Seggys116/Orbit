// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extensions_api_client.h"

#include <utility>

#include "extensions/browser/api/messaging/messaging_delegate.h"
#include "orbit/browser/orbit_managed_value_store_cache.h"
#include "orbit/browser/orbit_management_api_delegate.h"
#include "orbit/browser/orbit_messaging_delegate.h"
#include "orbit/browser/orbit_sync_value_store_cache.h"

namespace orbit {

OrbitExtensionsAPIClient::OrbitExtensionsAPIClient()
    : messaging_delegate_(std::make_unique<OrbitMessagingDelegate>()) {}

OrbitExtensionsAPIClient::~OrbitExtensionsAPIClient() = default;

extensions::MessagingDelegate*
OrbitExtensionsAPIClient::GetMessagingDelegate() {
  return messaging_delegate_.get();
}

extensions::ManagementAPIDelegate*
OrbitExtensionsAPIClient::CreateManagementAPIDelegate() const {
  return new OrbitManagementAPIDelegate();
}

void OrbitExtensionsAPIClient::AddAdditionalValueStoreCaches(
    content::BrowserContext* context,
    const scoped_refptr<value_store::ValueStoreFactory>& factory,
    extensions::SettingsChangedCallback observer,
    std::map<extensions::settings_namespace::Namespace,
             raw_ptr<extensions::ValueStoreCache, CtnExperimental>>* caches) {
  // StorageFrontend owns both from here on, tearing them down the same way
  // it does the LOCAL cache it built itself.
  (*caches)[extensions::settings_namespace::SYNC] =
      new OrbitSyncValueStoreCache(factory);
  (*caches)[extensions::settings_namespace::MANAGED] =
      new OrbitManagedValueStoreCache();
}

}  // namespace orbit
