// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_sync_value_store_cache.h"

#include <utility>

#include "components/value_store/value_store.h"
#include "components/value_store/value_store_factory.h"
#include "extensions/browser/api/storage/backend_task_runner.h"
#include "extensions/browser/api/storage/settings_namespace.h"
#include "extensions/browser/api/storage/value_store_util.h"
#include "extensions/common/api/storage.h"
#include "extensions/common/extension.h"

namespace orbit {

namespace {

// Quota limits come from storage.json's sync schema (100 KB total, 8 KB/item, 512 items).
// MAX_WRITE_OPERATIONS_PER_HOUR/_MINUTE aren't enforced -- Chrome doesn't enforce them either.
extensions::SettingsStorageQuotaEnforcer::Limits GetSyncQuotaLimits() {
  return extensions::SettingsStorageQuotaEnforcer::Limits{
      static_cast<size_t>(extensions::api::storage::sync::QUOTA_BYTES),
      static_cast<size_t>(extensions::api::storage::sync::QUOTA_BYTES_PER_ITEM),
      static_cast<size_t>(extensions::api::storage::sync::MAX_ITEMS)};
}

}  // namespace

OrbitSyncValueStoreCache::OrbitSyncValueStoreCache(
    scoped_refptr<value_store::ValueStoreFactory> factory)
    : storage_factory_(std::move(factory)), quota_(GetSyncQuotaLimits()) {}

OrbitSyncValueStoreCache::~OrbitSyncValueStoreCache() = default;

void OrbitSyncValueStoreCache::RunWithValueStoreForExtension(
    StorageCallback callback,
    scoped_refptr<const extensions::Extension> extension) {
  DCHECK(extensions::IsOnBackendSequence());
  // No WeakUnlimitedSettingsStorage here, unlike LOCAL: unlimitedStorage lifts local's
  // quota only, so sync writes past QUOTA_BYTES would be writes Chrome itself refuses.
  std::move(callback).Run(GetStorage(extension.get()));
}

void OrbitSyncValueStoreCache::DeleteStorageSoon(
    const extensions::ExtensionId& extension_id) {
  DCHECK(extensions::IsOnBackendSequence());
  storage_map_.erase(extension_id);

  extensions::value_store_util::DeleteValueStore(
      extensions::settings_namespace::SYNC,
      extensions::value_store_util::ModelType::APP, extension_id,
      storage_factory_);
  extensions::value_store_util::DeleteValueStore(
      extensions::settings_namespace::SYNC,
      extensions::value_store_util::ModelType::EXTENSION, extension_id,
      storage_factory_);
}

value_store::ValueStore* OrbitSyncValueStoreCache::GetStorage(
    const extensions::Extension* extension) {
  auto iter = storage_map_.find(extension->id());
  if (iter != storage_map_.end()) {
    return iter->second.get();
  }

  extensions::value_store_util::ModelType model_type =
      extension->is_app() ? extensions::value_store_util::ModelType::APP
                          : extensions::value_store_util::ModelType::EXTENSION;
  std::unique_ptr<value_store::ValueStore> store =
      extensions::value_store_util::CreateSettingsStore(
          extensions::settings_namespace::SYNC, model_type, extension->id(),
          storage_factory_);
  auto storage = std::make_unique<extensions::SettingsStorageQuotaEnforcer>(
      quota_, std::move(store));
  value_store::ValueStore* storage_ptr = storage.get();
  storage_map_[extension->id()] = std::move(storage);
  return storage_ptr;
}

}  // namespace orbit
