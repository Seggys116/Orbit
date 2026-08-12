// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_managed_value_store_cache.h"

#include <utility>

#include "components/value_store/value_store_change.h"
#include "extensions/browser/api/storage/backend_task_runner.h"
#include "extensions/common/extension.h"

namespace orbit {

namespace {

value_store::ValueStore::Status ReadOnlyError() {
  return value_store::ValueStore::Status(value_store::ValueStore::READ_ONLY,
                                         "This is a read-only store.");
}

value_store::ValueStore::ReadResult EmptyRead() {
  return value_store::ValueStore::ReadResult(
      base::DictValue(), value_store::ValueStore::Status());
}

}  // namespace

OrbitEmptyManagedValueStore::OrbitEmptyManagedValueStore() = default;

OrbitEmptyManagedValueStore::~OrbitEmptyManagedValueStore() = default;

size_t OrbitEmptyManagedValueStore::GetBytesInUse(const std::string& key) {
  return 0;
}

size_t OrbitEmptyManagedValueStore::GetBytesInUse(
    const std::vector<std::string>& keys) {
  return 0;
}

size_t OrbitEmptyManagedValueStore::GetBytesInUse() {
  return 0;
}

value_store::ValueStore::ReadResult OrbitEmptyManagedValueStore::GetKeys() {
  return EmptyRead();
}

value_store::ValueStore::ReadResult OrbitEmptyManagedValueStore::Get(
    const std::string& key) {
  return EmptyRead();
}

value_store::ValueStore::ReadResult OrbitEmptyManagedValueStore::Get(
    const std::vector<std::string>& keys) {
  return EmptyRead();
}

value_store::ValueStore::ReadResult OrbitEmptyManagedValueStore::Get() {
  return EmptyRead();
}

value_store::ValueStore::WriteResult OrbitEmptyManagedValueStore::Set(
    WriteOptions options,
    const std::string& key,
    const base::Value& value) {
  return WriteResult(ReadOnlyError());
}

value_store::ValueStore::WriteResult OrbitEmptyManagedValueStore::Set(
    WriteOptions options,
    const base::DictValue& values) {
  return WriteResult(ReadOnlyError());
}

value_store::ValueStore::WriteResult OrbitEmptyManagedValueStore::Remove(
    const std::string& key) {
  return WriteResult(ReadOnlyError());
}

value_store::ValueStore::WriteResult OrbitEmptyManagedValueStore::Remove(
    const std::vector<std::string>& keys) {
  return WriteResult(ReadOnlyError());
}

value_store::ValueStore::WriteResult OrbitEmptyManagedValueStore::Clear() {
  return WriteResult(ReadOnlyError());
}

OrbitManagedValueStoreCache::OrbitManagedValueStoreCache()
    : store_(std::make_unique<OrbitEmptyManagedValueStore>()) {}

OrbitManagedValueStoreCache::~OrbitManagedValueStoreCache() = default;

void OrbitManagedValueStoreCache::RunWithValueStoreForExtension(
    StorageCallback callback,
    scoped_refptr<const extensions::Extension> extension) {
  DCHECK(extensions::IsOnBackendSequence());
  std::move(callback).Run(store_.get());
}

void OrbitManagedValueStoreCache::DeleteStorageSoon(
    const extensions::ExtensionId& extension_id) {}

}  // namespace orbit
