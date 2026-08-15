// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_bookmarks_api.h"

#include <algorithm>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/strings/string_util.h"
#include "orbit/browser/orbit_bookmark_registry.h"
#include "url/gurl.h"

namespace orbit {

namespace {

// Verbatim from chrome/.../bookmarks/bookmarks_error_constants.cc.
constexpr char kNoNodeError[] = "Can't find bookmark for id.";
constexpr char kNoParentError[] = "Can't find parent bookmark for id.";
constexpr char kFolderNotEmptyError[] =
    "Can't remove non-empty folder (use recursive to force).";
constexpr char kInvalidIdError[] = "Bookmark id is invalid.";
constexpr char kInvalidIndexError[] = "Index out of bounds.";
constexpr char kInvalidParentError[] =
    "Parameter 'parentId' does not specify a folder.";
constexpr char kInvalidUrlError[] = "Invalid URL.";
constexpr char kModifySpecialError[] =
    "Can't modify the root bookmark folders.";
constexpr char kCannotSetUrlOfFolderError[] =
    "Can't set URL of a bookmark folder.";
constexpr char kInvalidMoveDestinationError[] =
    "Can't move a folder to itself or its descendant.";

constexpr char kNumberOfItemsError[] =
    "numberOfItems cannot be less than 1.";

constexpr char kSpaceIdPrefix[] = "s:";
constexpr char kPinnedIdPrefix[] = "p:";

OrbitBookmarkRegistry& Registry() {
  return OrbitBookmarkRegistry::GetInstance();
}

bool HasTree() {
  return !Registry().RootId().empty();
}

bool ReadId(const base::Value& value, std::string* id) {
  if (!value.is_string() || value.GetString().empty()) {
    return false;
  }
  *id = value.GetString();
  return true;
}

// Orbit's stand-in for Chrome's "Other Bookmarks" default.
std::string DefaultParentId() {
  OrbitBookmarkRegistry& registry = Registry();
  for (const std::string& space_id : registry.ChildIdsOf(registry.RootId())) {
    if (!base::StartsWith(space_id, kSpaceIdPrefix)) {
      continue;
    }
    for (const std::string& child_id : registry.ChildIdsOf(space_id)) {
      if (base::StartsWith(child_id, kPinnedIdPrefix)) {
        return child_id;
      }
    }
    return std::string();
  }
  return std::string();
}

bool HasAncestor(const std::string& id, const std::string& ancestor_id) {
  std::string current = id;
  while (!current.empty()) {
    if (current == ancestor_id) {
      return true;
    }
    current = Registry().ParentIdOf(current);
  }
  return false;
}

std::vector<std::string> TokenizeQuery(const std::string& query) {
  std::vector<std::string> tokens;
  std::string current;
  bool quoted = false;
  for (char character : query) {
    if (character == '"') {
      quoted = !quoted;
      continue;
    }
    if (!quoted && base::IsAsciiWhitespace(character)) {
      if (!current.empty()) {
        tokens.push_back(base::ToLowerASCII(current));
        current.clear();
      }
      continue;
    }
    current.push_back(character);
  }
  if (!current.empty()) {
    tokens.push_back(base::ToLowerASCII(current));
  }
  return tokens;
}

bool MatchesTokens(const std::vector<std::string>& tokens,
                   const std::string& title,
                   const std::string& url) {
  const std::string lower_title = base::ToLowerASCII(title);
  const std::string lower_url = base::ToLowerASCII(url);
  for (const std::string& token : tokens) {
    if (lower_title.find(token) == std::string::npos &&
        lower_url.find(token) == std::string::npos) {
      return false;
    }
  }
  return true;
}

std::string StringOr(const base::DictValue& node, const char* key) {
  const std::string* value = node.FindString(key);
  return value ? *value : std::string();
}

// False only when "index" is present but not an integer.
bool ReadOptionalIndex(const base::DictValue& source, std::optional<int>* out) {
  const base::Value* raw = source.Find("index");
  if (!raw || raw->is_none()) {
    return true;
  }
  if (!raw->is_int()) {
    return false;
  }
  *out = raw->GetInt();
  return true;
}

}  // namespace

ExtensionFunction::ResponseAction BookmarksGetFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  if (args().empty()) {
    return RespondNow(BadMessage());
  }

  std::vector<std::string> ids;
  const base::Value& argument = args()[0];
  if (const base::ListValue* list = argument.GetIfList()) {
    if (list->empty()) {
      return RespondNow(BadMessage());
    }
    for (const base::Value& entry : *list) {
      std::string id;
      if (!ReadId(entry, &id)) {
        return RespondNow(Error(kInvalidIdError));
      }
      ids.push_back(id);
    }
  } else {
    std::string id;
    if (!ReadId(argument, &id)) {
      return RespondNow(Error(kInvalidIdError));
    }
    ids.push_back(id);
  }

  base::ListValue results;
  for (const std::string& id : ids) {
    if (!Registry().HasNode(id)) {
      return RespondNow(Error(kNoNodeError));
    }
    results.Append(Registry().BuildNode(id, false));
  }
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction BookmarksGetChildrenFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  std::string id;
  if (args().empty() || !ReadId(args()[0], &id)) {
    return RespondNow(Error(kInvalidIdError));
  }
  if (!Registry().HasNode(id)) {
    return RespondNow(Error(kNoNodeError));
  }

  base::ListValue results;
  for (const std::string& child_id : Registry().ChildIdsOf(id)) {
    results.Append(Registry().BuildNode(child_id, false));
  }
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction BookmarksGetRecentFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  if (args().empty() || !args()[0].is_int()) {
    return RespondNow(BadMessage());
  }
  const int count = args()[0].GetInt();
  if (count < 1) {
    return RespondNow(Error(kNumberOfItemsError));
  }

  struct Entry {
    std::string id;
    std::optional<double> date_added;
  };
  std::vector<Entry> entries;
  for (const std::string& id : Registry().AllIdsPreOrder()) {
    const base::DictValue node = Registry().BuildNode(id, false);
    if (!node.FindString("url")) {
      continue;
    }
    entries.push_back(Entry{id, node.FindDouble("dateAdded")});
  }
  // Stable so the pre-order position breaks ties, including between the nodes
  // Orbit stores no creation date for.
  std::stable_sort(entries.begin(), entries.end(),
                   [](const Entry& lhs, const Entry& rhs) {
                     if (lhs.date_added.has_value() !=
                         rhs.date_added.has_value()) {
                       return lhs.date_added.has_value();
                     }
                     if (!lhs.date_added.has_value()) {
                       return false;
                     }
                     return *lhs.date_added > *rhs.date_added;
                   });

  base::ListValue results;
  const size_t limit =
      std::min(static_cast<size_t>(count), entries.size());
  for (size_t i = 0; i < limit; ++i) {
    results.Append(Registry().BuildNode(entries[i].id, false));
  }
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction BookmarksGetTreeFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  base::ListValue results;
  results.Append(Registry().BuildNode(Registry().RootId(), true));
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction BookmarksGetSubTreeFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  std::string id;
  if (args().empty() || !ReadId(args()[0], &id)) {
    return RespondNow(Error(kInvalidIdError));
  }
  if (!Registry().HasNode(id)) {
    return RespondNow(Error(kNoNodeError));
  }
  base::ListValue results;
  results.Append(Registry().BuildNode(id, true));
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction BookmarksSearchFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  if (args().empty()) {
    return RespondNow(BadMessage());
  }

  std::vector<std::string> tokens;
  bool has_word_query = false;
  std::optional<std::string> url_filter;
  std::optional<std::string> title_filter;

  const base::Value& argument = args()[0];
  if (argument.is_string()) {
    tokens = TokenizeQuery(argument.GetString());
    has_word_query = true;
  } else if (const base::DictValue* query = argument.GetIfDict()) {
    if (const std::string* words = query->FindString("query")) {
      tokens = TokenizeQuery(*words);
      has_word_query = true;
    }
    if (const std::string* url = query->FindString("url")) {
      url_filter = *url;
    }
    if (const std::string* title = query->FindString("title")) {
      title_filter = *title;
    }
  } else {
    return RespondNow(BadMessage());
  }

  base::ListValue results;
  if (has_word_query && tokens.empty()) {
    return RespondNow(WithArguments(std::move(results)));
  }

  std::string canonical_url;
  if (url_filter) {
    const GURL url(*url_filter);
    if (!url.is_valid()) {
      return RespondNow(WithArguments(std::move(results)));
    }
    canonical_url = url.spec();
  }

  for (const std::string& id : Registry().AllIdsPreOrder()) {
    if (Registry().IsPermanent(id)) {
      continue;
    }
    base::DictValue node = Registry().BuildNode(id, false);
    const bool is_url_node = node.FindString("url") != nullptr;
    const std::string title = StringOr(node, "title");
    const std::string url = StringOr(node, "url");

    if (!canonical_url.empty() &&
        (!is_url_node || GURL(url).spec() != canonical_url)) {
      continue;
    }
    if (title_filter && title != *title_filter) {
      continue;
    }
    if (!tokens.empty() && !MatchesTokens(tokens, title, url)) {
      continue;
    }
    results.Append(std::move(node));
  }
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction BookmarksCreateFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  const base::DictValue* details =
      args().empty() ? nullptr : args()[0].GetIfDict();
  if (!details) {
    return RespondNow(BadMessage());
  }

  std::string parent_id;
  const base::Value* raw_parent = details->Find("parentId");
  if (raw_parent && !raw_parent->is_none()) {
    if (!ReadId(*raw_parent, &parent_id)) {
      return RespondNow(Error(kInvalidIdError));
    }
  } else {
    parent_id = DefaultParentId();
  }
  if (parent_id.empty() || !Registry().HasNode(parent_id)) {
    return RespondNow(Error(kNoParentError));
  }
  if (parent_id == Registry().RootId()) {
    return RespondNow(Error(kModifySpecialError));
  }
  if (!Registry().IsFolder(parent_id)) {
    return RespondNow(Error(kInvalidParentError));
  }

  std::optional<int> index;
  if (!ReadOptionalIndex(*details, &index)) {
    return RespondNow(BadMessage());
  }
  if (index) {
    const int child_count =
        static_cast<int>(Registry().ChildIdsOf(parent_id).size());
    if (*index < 0 || *index > child_count) {
      return RespondNow(Error(kInvalidIndexError));
    }
  }

  std::string title;
  if (const std::string* raw_title = details->FindString("title")) {
    title = *raw_title;
  }

  std::string url;
  bool has_url = false;
  if (const std::string* raw_url = details->FindString("url")) {
    url = *raw_url;
    has_url = !url.empty();
    if (has_url && !GURL(url).is_valid()) {
      return RespondNow(Error(kInvalidUrlError));
    }
  }

  base::DictValue request;
  request.Set("parentId", parent_id);
  request.Set("index", index ? base::Value(*index) : base::Value());
  request.Set("title", title);
  request.Set("url", has_url ? base::Value(url) : base::Value());

  std::string created_id;
  std::string error;
  if (!Registry().Request("create", std::move(request), &created_id, &error)) {
    return RespondNow(Error(error));
  }
  if (!Registry().HasNode(created_id)) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  return RespondNow(WithArguments(Registry().BuildNode(created_id, false)));
}

ExtensionFunction::ResponseAction BookmarksMoveFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  std::string id;
  if (args().empty() || !ReadId(args()[0], &id)) {
    return RespondNow(Error(kInvalidIdError));
  }
  const base::DictValue* destination =
      args().size() < 2 ? nullptr : args()[1].GetIfDict();
  if (!destination) {
    return RespondNow(BadMessage());
  }

  if (!Registry().HasNode(id)) {
    return RespondNow(Error(kNoNodeError));
  }
  if (Registry().IsPermanent(id)) {
    return RespondNow(Error(kModifySpecialError));
  }

  std::string parent_id;
  const base::Value* raw_parent = destination->Find("parentId");
  if (raw_parent && !raw_parent->is_none()) {
    if (!ReadId(*raw_parent, &parent_id)) {
      return RespondNow(Error(kInvalidIdError));
    }
  } else {
    parent_id = Registry().ParentIdOf(id);
  }
  if (parent_id.empty() || !Registry().HasNode(parent_id)) {
    return RespondNow(Error(kNoParentError));
  }
  if (parent_id == Registry().RootId()) {
    return RespondNow(Error(kModifySpecialError));
  }
  if (!Registry().IsFolder(parent_id)) {
    return RespondNow(Error(kInvalidParentError));
  }
  if (HasAncestor(parent_id, id)) {
    return RespondNow(Error(kInvalidMoveDestinationError));
  }

  std::optional<int> index;
  if (!ReadOptionalIndex(*destination, &index)) {
    return RespondNow(BadMessage());
  }
  if (index) {
    const int child_count =
        static_cast<int>(Registry().ChildIdsOf(parent_id).size());
    if (*index < 0 || *index > child_count) {
      return RespondNow(Error(kInvalidIndexError));
    }
  }

  base::DictValue request;
  request.Set("id", id);
  request.Set("parentId", parent_id);
  request.Set("index", index ? base::Value(*index) : base::Value());

  std::string moved_id;
  std::string error;
  if (!Registry().Request("move", std::move(request), &moved_id, &error)) {
    return RespondNow(Error(error));
  }
  if (!Registry().HasNode(moved_id)) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  return RespondNow(WithArguments(Registry().BuildNode(moved_id, false)));
}

ExtensionFunction::ResponseAction BookmarksUpdateFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  std::string id;
  if (args().empty() || !ReadId(args()[0], &id)) {
    return RespondNow(Error(kInvalidIdError));
  }
  const base::DictValue* changes =
      args().size() < 2 ? nullptr : args()[1].GetIfDict();
  if (!changes) {
    return RespondNow(BadMessage());
  }

  std::optional<std::string> title;
  if (const std::string* raw_title = changes->FindString("title")) {
    title = *raw_title;
  }

  std::string url;
  bool has_url = false;
  if (const std::string* raw_url = changes->FindString("url")) {
    url = *raw_url;
    has_url = !url.empty();
    if (has_url && !GURL(url).is_valid()) {
      return RespondNow(Error(kInvalidUrlError));
    }
  }

  if (!Registry().HasNode(id)) {
    return RespondNow(Error(kNoNodeError));
  }
  if (Registry().IsPermanent(id)) {
    return RespondNow(Error(kModifySpecialError));
  }
  if (has_url && Registry().IsFolder(id)) {
    return RespondNow(Error(kCannotSetUrlOfFolderError));
  }

  base::DictValue request;
  request.Set("id", id);
  request.Set("title", title ? base::Value(*title) : base::Value());
  request.Set("url", has_url ? base::Value(url) : base::Value());

  std::string updated_id;
  std::string error;
  if (!Registry().Request("update", std::move(request), &updated_id, &error)) {
    return RespondNow(Error(error));
  }
  if (!Registry().HasNode(updated_id)) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  return RespondNow(WithArguments(Registry().BuildNode(updated_id, false)));
}

ExtensionFunction::ResponseAction BookmarksRemoveFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  std::string id;
  if (args().empty() || !ReadId(args()[0], &id)) {
    return RespondNow(Error(kInvalidIdError));
  }
  if (!Registry().HasNode(id)) {
    return RespondNow(Error(kNoNodeError));
  }
  if (Registry().IsPermanent(id)) {
    return RespondNow(Error(kModifySpecialError));
  }
  if (Registry().IsFolder(id) && !Registry().ChildIdsOf(id).empty()) {
    return RespondNow(Error(kFolderNotEmptyError));
  }

  base::DictValue request;
  request.Set("id", id);

  std::string removed_id;
  std::string error;
  if (!Registry().Request("remove", std::move(request), &removed_id, &error)) {
    return RespondNow(Error(error));
  }
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction BookmarksRemoveTreeFunction::Run() {
  if (!HasTree()) {
    return RespondNow(Error(kBookmarksUnavailableError));
  }
  std::string id;
  if (args().empty() || !ReadId(args()[0], &id)) {
    return RespondNow(Error(kInvalidIdError));
  }
  if (!Registry().HasNode(id)) {
    return RespondNow(Error(kNoNodeError));
  }
  if (Registry().IsPermanent(id)) {
    return RespondNow(Error(kModifySpecialError));
  }

  base::DictValue request;
  request.Set("id", id);

  std::string removed_id;
  std::string error;
  if (!Registry().Request("removeTree", std::move(request), &removed_id,
                          &error)) {
    return RespondNow(Error(error));
  }
  return RespondNow(NoArguments());
}

}  // namespace orbit
