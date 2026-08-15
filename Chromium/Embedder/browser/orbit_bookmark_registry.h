// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_BOOKMARK_REGISTRY_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_BOOKMARK_REGISTRY_H_

#include <map>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/values.h"
#include "orbit/bridge/orbit_bridge_api.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

inline constexpr char kBookmarksUnavailableError[] =
    "Bookmarks are not available.";

class OrbitBookmarkRegistry {
 public:
  static OrbitBookmarkRegistry& GetInstance();

  OrbitBookmarkRegistry(const OrbitBookmarkRegistry&) = delete;
  OrbitBookmarkRegistry& operator=(const OrbitBookmarkRegistry&) = delete;

  void SetRequestCallback(OrbitBookmarksRequestCallback callback, void* opaque);
  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();
  void SetTree(const std::string& tree_json);

  bool HasNode(const std::string& id) const;
  bool IsFolder(const std::string& id) const;
  bool IsPermanent(const std::string& id) const;
  std::string RootId() const;
  std::string ParentIdOf(const std::string& id) const;
  std::vector<std::string> ChildIdsOf(const std::string& id) const;
  std::vector<std::string> AllIdsPreOrder() const;
  // Flat node value (no "children") or, with recursive, the whole subtree.
  base::DictValue BuildNode(const std::string& id, bool recursive) const;

  // Synchronous; on success `out_id` names the node in the refreshed tree.
  bool Request(const std::string& method,
               base::DictValue args,
               std::string* out_id,
               std::string* error);

 private:
  friend class base::NoDestructor<OrbitBookmarkRegistry>;

  struct Node {
    std::string id;
    std::string parent_id;
    int index = 0;
    std::string title;
    std::string url;
    bool has_url = false;
    std::optional<double> date_added;
    bool permanent = false;
    std::vector<std::string> children;
  };
  using NodeMap = std::map<std::string, Node>;

  OrbitBookmarkRegistry();
  ~OrbitBookmarkRegistry();

  static bool ParseTree(const std::string& tree_json,
                        NodeMap* out_nodes,
                        std::string* out_root_id);
  static bool FlattenNode(const base::DictValue& value,
                          const std::string& parent_id,
                          int index,
                          NodeMap* out_nodes,
                          std::string* out_id);
  static std::vector<std::string> PreOrderIn(const NodeMap& nodes,
                                             const std::string& root_id);
  static base::DictValue BuildNodeIn(const NodeMap& nodes,
                                     const std::string& id,
                                     bool recursive);

  void DiffAndBroadcast(const NodeMap& before,
                        const std::string& before_root_id,
                        const NodeMap& after,
                        const std::string& after_root_id) const;

  raw_ptr<content::BrowserContext> browser_context_ = nullptr;
  OrbitBookmarksRequestCallback request_callback_ = nullptr;
  raw_ptr<void> request_opaque_ = nullptr;

  NodeMap nodes_;
  std::string root_id_;
  // The first snapshot is the startup state, which fires no events.
  bool has_tree_ = false;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_BOOKMARK_REGISTRY_H_
