// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_bookmark_registry.h"

#include <algorithm>
#include <memory>
#include <set>
#include <utility>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "content/public/browser/browser_context.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"

namespace orbit {

namespace {

constexpr char kOnCreatedEvent[] = "bookmarks.onCreated";
constexpr char kOnRemovedEvent[] = "bookmarks.onRemoved";
constexpr char kOnChangedEvent[] = "bookmarks.onChanged";
constexpr char kOnMovedEvent[] = "bookmarks.onMoved";

struct ReplyState {
  bool received = false;
  std::string json;
};

void OnSwiftReply(void* reply_ctx, const char* json) {
  ReplyState* state = static_cast<ReplyState*>(reply_ctx);
  if (!state) {
    return;
  }
  state->received = true;
  state->json = json ? std::string(json) : std::string();
}

void Broadcast(content::BrowserContext* browser_context,
               extensions::events::HistogramValue histogram_value,
               const char* event_name,
               base::ListValue args) {
  if (!browser_context) {
    return;
  }
  extensions::EventRouter* router =
      extensions::EventRouter::Get(browser_context);
  if (!router) {
    return;
  }
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      histogram_value, event_name, std::move(args), browser_context));
}

std::set<std::string> CommonSubsequence(const std::vector<std::string>& a,
                                        const std::vector<std::string>& b) {
  std::vector<std::vector<size_t>> lengths(
      a.size() + 1, std::vector<size_t>(b.size() + 1, 0u));
  for (size_t i = 0; i < a.size(); ++i) {
    for (size_t j = 0; j < b.size(); ++j) {
      lengths[i + 1][j + 1] =
          a[i] == b[j] ? lengths[i][j] + 1
                       : std::max(lengths[i][j + 1], lengths[i + 1][j]);
    }
  }
  std::set<std::string> common;
  size_t i = a.size();
  size_t j = b.size();
  while (i > 0 && j > 0) {
    if (a[i - 1] == b[j - 1]) {
      common.insert(a[i - 1]);
      --i;
      --j;
    } else if (lengths[i - 1][j] >= lengths[i][j - 1]) {
      --i;
    } else {
      --j;
    }
  }
  return common;
}

}  // namespace

// static
OrbitBookmarkRegistry& OrbitBookmarkRegistry::GetInstance() {
  static base::NoDestructor<OrbitBookmarkRegistry> instance;
  return *instance;
}

OrbitBookmarkRegistry::OrbitBookmarkRegistry() = default;
OrbitBookmarkRegistry::~OrbitBookmarkRegistry() = default;

void OrbitBookmarkRegistry::SetRequestCallback(
    OrbitBookmarksRequestCallback callback, void* opaque) {
  request_callback_ = callback;
  request_opaque_ = opaque;
}

void OrbitBookmarkRegistry::StartObserving(
    content::BrowserContext* browser_context) {
  browser_context_ = browser_context;
}

void OrbitBookmarkRegistry::StopObserving() {
  browser_context_ = nullptr;
}

// static
bool OrbitBookmarkRegistry::FlattenNode(const base::DictValue& value,
                                        const std::string& parent_id,
                                        int index,
                                        NodeMap* out_nodes,
                                        std::string* out_id) {
  const std::string* id = value.FindString("id");
  if (!id || id->empty() || out_nodes->contains(*id)) {
    return false;
  }

  Node node;
  node.id = *id;
  node.parent_id = parent_id;
  node.index = index;
  if (const std::string* title = value.FindString("title")) {
    node.title = *title;
  }
  if (const std::string* url = value.FindString("url")) {
    node.url = *url;
    node.has_url = true;
  }
  if (std::optional<double> date_added = value.FindDouble("dateAdded")) {
    node.date_added = *date_added;
  }
  node.permanent = value.FindBool("permanent").value_or(false);

  auto inserted = out_nodes->emplace(*id, std::move(node)).first;
  *out_id = inserted->first;

  if (const base::ListValue* children = value.FindList("children")) {
    int child_index = 0;
    for (const base::Value& child : *children) {
      const base::DictValue* child_dict = child.GetIfDict();
      std::string child_id;
      if (child_dict && FlattenNode(*child_dict, inserted->first, child_index,
                                    out_nodes, &child_id)) {
        inserted->second.children.push_back(child_id);
        ++child_index;
      }
    }
  }
  return true;
}

// static
bool OrbitBookmarkRegistry::ParseTree(const std::string& tree_json,
                                      NodeMap* out_nodes,
                                      std::string* out_root_id) {
  std::optional<base::DictValue> parsed =
      base::JSONReader::ReadDict(tree_json, base::JSON_PARSE_RFC);
  if (!parsed) {
    return false;
  }
  return FlattenNode(*parsed, std::string(), 0, out_nodes, out_root_id);
}

// static
std::vector<std::string> OrbitBookmarkRegistry::PreOrderIn(
    const NodeMap& nodes, const std::string& root_id) {
  std::vector<std::string> ordered;
  if (root_id.empty() || !nodes.contains(root_id)) {
    return ordered;
  }
  std::vector<std::string> stack{root_id};
  while (!stack.empty()) {
    const std::string id = stack.back();
    stack.pop_back();
    auto it = nodes.find(id);
    if (it == nodes.end()) {
      continue;
    }
    ordered.push_back(id);
    const std::vector<std::string>& children = it->second.children;
    for (auto child = children.rbegin(); child != children.rend(); ++child) {
      stack.push_back(*child);
    }
  }
  return ordered;
}

void OrbitBookmarkRegistry::SetTree(const std::string& tree_json) {
  NodeMap next;
  std::string next_root;
  if (!ParseTree(tree_json, &next, &next_root)) {
    return;
  }

  NodeMap previous = std::move(nodes_);
  const std::string previous_root = root_id_;
  const bool had_tree = has_tree_;

  nodes_ = std::move(next);
  root_id_ = next_root;
  has_tree_ = true;

  if (had_tree) {
    DiffAndBroadcast(previous, previous_root, nodes_, root_id_);
  }
}

void OrbitBookmarkRegistry::DiffAndBroadcast(
    const NodeMap& before,
    const std::string& before_root_id,
    const NodeMap& after,
    const std::string& after_root_id) const {
  const std::vector<std::string> before_order =
      PreOrderIn(before, before_root_id);
  const std::vector<std::string> after_order = PreOrderIn(after, after_root_id);

  for (const std::string& id : before_order) {
    if (after.contains(id)) {
      continue;
    }
    const Node& node = before.at(id);
    // Chrome fires once for a removed folder and never for its contents.
    if (!node.parent_id.empty() && !after.contains(node.parent_id)) {
      continue;
    }
    base::DictValue info;
    info.Set("parentId", node.parent_id);
    info.Set("index", node.index);
    // The removed node is already detached, so upstream strips both, and an
    // extension that reads them off the node would get a stale parent.
    base::DictValue removed = BuildNodeIn(before, id, true);
    removed.Remove("parentId");
    removed.Remove("index");
    info.Set("node", std::move(removed));
    base::ListValue args;
    args.Append(id);
    args.Append(std::move(info));
    Broadcast(browser_context_, extensions::events::BOOKMARKS_ON_REMOVED,
              kOnRemovedEvent, std::move(args));
  }

  for (const std::string& id : after_order) {
    if (before.contains(id)) {
      continue;
    }
    const Node& node = after.at(id);
    if (!node.parent_id.empty() && !before.contains(node.parent_id)) {
      continue;
    }
    base::ListValue args;
    args.Append(id);
    args.Append(BuildNodeIn(after, id, true));
    Broadcast(browser_context_, extensions::events::BOOKMARKS_ON_CREATED,
              kOnCreatedEvent, std::move(args));
  }

  std::set<std::string> moved;
  for (const std::string& id : after_order) {
    auto previous = before.find(id);
    if (previous != before.end() &&
        previous->second.parent_id != after.at(id).parent_id) {
      moved.insert(id);
    }
  }
  // A sibling's insert or removal shifts raw indices without moving anything.
  for (const std::string& parent_id : after_order) {
    auto previous_parent = before.find(parent_id);
    if (previous_parent == before.end()) {
      continue;
    }
    auto stayed = [&](const std::string& child_id) {
      auto before_child = before.find(child_id);
      auto after_child = after.find(child_id);
      return before_child != before.end() && after_child != after.end() &&
             before_child->second.parent_id == parent_id &&
             after_child->second.parent_id == parent_id;
    };
    std::vector<std::string> old_sequence;
    for (const std::string& child_id : previous_parent->second.children) {
      if (stayed(child_id)) {
        old_sequence.push_back(child_id);
      }
    }
    std::vector<std::string> new_sequence;
    for (const std::string& child_id : after.at(parent_id).children) {
      if (stayed(child_id)) {
        new_sequence.push_back(child_id);
      }
    }
    const std::set<std::string> common =
        CommonSubsequence(old_sequence, new_sequence);
    for (const std::string& child_id : new_sequence) {
      if (!common.contains(child_id)) {
        moved.insert(child_id);
      }
    }
  }

  for (const std::string& id : after_order) {
    if (!moved.contains(id)) {
      continue;
    }
    const Node& node = after.at(id);
    const Node& previous = before.at(id);
    base::DictValue info;
    info.Set("parentId", node.parent_id);
    info.Set("index", node.index);
    info.Set("oldParentId", previous.parent_id);
    info.Set("oldIndex", previous.index);
    base::ListValue args;
    args.Append(id);
    args.Append(std::move(info));
    Broadcast(browser_context_, extensions::events::BOOKMARKS_ON_MOVED,
              kOnMovedEvent, std::move(args));
  }

  for (const std::string& id : after_order) {
    auto previous = before.find(id);
    if (previous == before.end()) {
      continue;
    }
    const Node& node = after.at(id);
    if (node.title == previous->second.title &&
        node.url == previous->second.url) {
      continue;
    }
    base::DictValue info;
    info.Set("title", node.title);
    if (node.has_url) {
      info.Set("url", node.url);
    }
    base::ListValue args;
    args.Append(id);
    args.Append(std::move(info));
    Broadcast(browser_context_, extensions::events::BOOKMARKS_ON_CHANGED,
              kOnChangedEvent, std::move(args));
  }
}

bool OrbitBookmarkRegistry::HasNode(const std::string& id) const {
  return nodes_.contains(id);
}

bool OrbitBookmarkRegistry::IsFolder(const std::string& id) const {
  auto it = nodes_.find(id);
  return it != nodes_.end() && !it->second.has_url;
}

bool OrbitBookmarkRegistry::IsPermanent(const std::string& id) const {
  auto it = nodes_.find(id);
  return it != nodes_.end() && it->second.permanent;
}

std::string OrbitBookmarkRegistry::RootId() const {
  return root_id_;
}

std::string OrbitBookmarkRegistry::ParentIdOf(const std::string& id) const {
  auto it = nodes_.find(id);
  return it == nodes_.end() ? std::string() : it->second.parent_id;
}

std::vector<std::string> OrbitBookmarkRegistry::ChildIdsOf(
    const std::string& id) const {
  auto it = nodes_.find(id);
  return it == nodes_.end() ? std::vector<std::string>() : it->second.children;
}

std::vector<std::string> OrbitBookmarkRegistry::AllIdsPreOrder() const {
  return PreOrderIn(nodes_, root_id_);
}

// static
base::DictValue OrbitBookmarkRegistry::BuildNodeIn(const NodeMap& nodes,
                                                   const std::string& id,
                                                   bool recursive) {
  base::DictValue value;
  auto it = nodes.find(id);
  if (it == nodes.end()) {
    return value;
  }
  const Node& node = it->second;

  value.Set("id", node.id);
  if (!node.parent_id.empty()) {
    value.Set("parentId", node.parent_id);
    value.Set("index", node.index);
  }
  value.Set("title", node.title);
  if (node.has_url) {
    value.Set("url", node.url);
  }
  if (node.date_added) {
    value.Set("dateAdded", *node.date_added);
  }
  value.Set("syncing", false);

  if (recursive && !node.has_url) {
    base::ListValue children;
    for (const std::string& child_id : node.children) {
      children.Append(BuildNodeIn(nodes, child_id, true));
    }
    value.Set("children", std::move(children));
  }
  return value;
}

base::DictValue OrbitBookmarkRegistry::BuildNode(const std::string& id,
                                                 bool recursive) const {
  return BuildNodeIn(nodes_, id, recursive);
}

bool OrbitBookmarkRegistry::Request(const std::string& method,
                                    base::DictValue args,
                                    std::string* out_id,
                                    std::string* error) {
  if (!request_callback_) {
    *error = kBookmarksUnavailableError;
    return false;
  }

  std::string args_json;
  base::JSONWriter::Write(args, &args_json);

  ReplyState state;
  request_callback_(request_opaque_, method.c_str(), args_json.c_str(),
                    &OnSwiftReply, &state);

  if (state.received) {
    std::optional<base::DictValue> reply =
        base::JSONReader::ReadDict(state.json, base::JSON_PARSE_RFC);
    if (reply) {
      if (const std::string* message = reply->FindString("error")) {
        *error = *message;
        return false;
      }
      if (const std::string* id = reply->FindString("id")) {
        *out_id = *id;
        return true;
      }
    }
  }

  *error = kBookmarksUnavailableError;
  return false;
}

}  // namespace orbit
