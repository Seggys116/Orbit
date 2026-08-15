// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_REGISTRY_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_REGISTRY_H_

#include <stddef.h>

#include <map>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/values.h"
#include "orbit/bridge/orbit_bridge_api.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

class OrbitDownloadRegistry {
 public:
  static OrbitDownloadRegistry& GetInstance();

  OrbitDownloadRegistry(const OrbitDownloadRegistry&) = delete;
  OrbitDownloadRegistry& operator=(const OrbitDownloadRegistry&) = delete;

  void SetRequestCallback(OrbitDownloadsRequestCallback callback, void* opaque);
  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();
  content::BrowserContext* browser_context() const { return browser_context_; }

  void SetItems(const std::string& items_json);

  void Refresh();

  const base::DictValue* GetItem(int id) const;
  std::vector<const base::DictValue*> AllItems() const;
  std::string GuidForId(int id) const;

  bool Request(const std::string& method,
               base::DictValue args,
               std::string* error);

  // Runs later if the snapshot naming `guid` has not arrived yet.
  void ResolveIdForGuid(const std::string& guid,
                        base::OnceCallback<void(int)> callback);

 private:
  friend class base::NoDestructor<OrbitDownloadRegistry>;

  OrbitDownloadRegistry();
  ~OrbitDownloadRegistry();

  base::DictValue BuildItem(const base::DictValue& snapshot_item) const;
  void FireCreated(const base::DictValue& item) const;
  void FireChanged(base::DictValue delta) const;
  void FireErased(int id) const;

  int IdForGuidInSnapshot(const std::string& guid) const;
  void RunPendingWaiters();

  raw_ptr<content::BrowserContext> browser_context_ = nullptr;

  base::ListValue snapshot_;
  base::ListValue items_;
  std::map<int, size_t> index_by_id_;
  std::map<int, std::string> guid_by_id_;
  bool emitted_once_ = false;

  std::vector<std::pair<std::string, base::OnceCallback<void(int)>>> waiters_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_REGISTRY_H_
