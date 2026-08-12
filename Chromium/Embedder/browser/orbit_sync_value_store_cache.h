// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.storage.sync with no sync engine: durable local store, no replication, matching
// Chrome's own signed-out-profile behaviour. Must stay registered or writes fail silently.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_SYNC_VALUE_STORE_CACHE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_SYNC_VALUE_STORE_CACHE_H_

#include <map>
#include <memory>
#include <string>

#include "base/memory/scoped_refptr.h"
#include "extensions/browser/api/storage/settings_storage_quota_enforcer.h"
#include "extensions/browser/api/storage/value_store_cache.h"
#include "extensions/common/extension_id.h"

namespace value_store {
class ValueStore;
class ValueStoreFactory;
}  // namespace value_store

namespace orbit {

class OrbitSyncValueStoreCache : public extensions::ValueStoreCache {
 public:
  explicit OrbitSyncValueStoreCache(
      scoped_refptr<value_store::ValueStoreFactory> factory);
  OrbitSyncValueStoreCache(const OrbitSyncValueStoreCache&) = delete;
  OrbitSyncValueStoreCache& operator=(const OrbitSyncValueStoreCache&) = delete;
  ~OrbitSyncValueStoreCache() override;

  // extensions::ValueStoreCache:
  void RunWithValueStoreForExtension(
      StorageCallback callback,
      scoped_refptr<const extensions::Extension> extension) override;
  void DeleteStorageSoon(const extensions::ExtensionId& extension_id) override;

 private:
  value_store::ValueStore* GetStorage(const extensions::Extension* extension);

  const scoped_refptr<value_store::ValueStoreFactory> storage_factory_;
  const extensions::SettingsStorageQuotaEnforcer::Limits quota_;
  std::map<std::string, std::unique_ptr<value_store::ValueStore>> storage_map_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_SYNC_VALUE_STORE_CACHE_H_
