// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.storage.managed with no policy provider: reads return {}, writes fail
// READ_ONLY. Must stay registered; omitting it breaks unguarded managed.get() callers.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_MANAGED_VALUE_STORE_CACHE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_MANAGED_VALUE_STORE_CACHE_H_

#include <memory>

#include "components/value_store/value_store.h"
#include "extensions/browser/api/storage/value_store_cache.h"
#include "extensions/common/extension_id.h"
#include "components/value_store/value_store_factory.h"

namespace orbit {

// A ValueStore holding nothing, that cannot be written to. Every read
// succeeds and reports emptiness; every write fails READ_ONLY with the same
// message Chrome's PolicyValueStore uses.
class OrbitEmptyManagedValueStore : public value_store::ValueStore {
 public:
  OrbitEmptyManagedValueStore();
  OrbitEmptyManagedValueStore(const OrbitEmptyManagedValueStore&) = delete;
  OrbitEmptyManagedValueStore& operator=(const OrbitEmptyManagedValueStore&) =
      delete;
  ~OrbitEmptyManagedValueStore() override;

  // value_store::ValueStore:
  size_t GetBytesInUse(const std::string& key) override;
  size_t GetBytesInUse(const std::vector<std::string>& keys) override;
  size_t GetBytesInUse() override;
  ReadResult GetKeys() override;
  ReadResult Get(const std::string& key) override;
  ReadResult Get(const std::vector<std::string>& keys) override;
  ReadResult Get() override;
  WriteResult Set(WriteOptions options,
                  const std::string& key,
                  const base::Value& value) override;
  WriteResult Set(WriteOptions options, const base::DictValue& values) override;
  WriteResult Remove(const std::string& key) override;
  WriteResult Remove(const std::vector<std::string>& keys) override;
  WriteResult Clear() override;
};

class OrbitManagedValueStoreCache : public extensions::ValueStoreCache {
 public:
  OrbitManagedValueStoreCache();
  OrbitManagedValueStoreCache(const OrbitManagedValueStoreCache&) = delete;
  OrbitManagedValueStoreCache& operator=(const OrbitManagedValueStoreCache&) =
      delete;
  ~OrbitManagedValueStoreCache() override;

  // extensions::ValueStoreCache:
  void RunWithValueStoreForExtension(
      StorageCallback callback,
      scoped_refptr<const extensions::Extension> extension) override;
  void DeleteStorageSoon(const extensions::ExtensionId& extension_id) override;

 private:
  // One instance for every extension: it holds no per-extension state because
  // there is no per-extension policy to hold.
  std::unique_ptr<OrbitEmptyManagedValueStore> store_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_MANAGED_VALUE_STORE_CACHE_H_
