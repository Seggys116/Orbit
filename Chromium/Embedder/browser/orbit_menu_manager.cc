// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_menu_manager.h"

#include <algorithm>
#include <ranges>
#include <tuple>
#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_api_frame_id_map.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/state_store.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/background_info.h"
#include "extensions/common/url_pattern.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom-shared.h"
#include "ui/gfx/text_elider.h"
#include "url/gurl.h"

namespace orbit {

namespace {

constexpr char kContextMenusStorageKey[] = "context_menus";

constexpr char kCheckedKey[] = "checked";
constexpr char kContextsKey[] = "contexts";
constexpr char kDocumentURLPatternsKey[] = "document_url_patterns";
constexpr char kEnabledKey[] = "enabled";
constexpr char kParentUIDKey[] = "parent_uid";
constexpr char kStringUIDKey[] = "string_uid";
constexpr char kTargetURLPatternsKey[] = "target_url_patterns";
constexpr char kTitleKey[] = "title";
constexpr char kTypeKey[] = "type";
constexpr char kVisibleKey[] = "visible";

constexpr int kWriteDelayInSeconds = 1;

// The longest selection chrome.contextMenus will substitute into a %s title;
// RenderViewContextMenuBase::kMaxSelectionTextLength.
constexpr size_t kMaxSelectionTextLength = 50;

void SetIdKeyValue(base::DictValue& properties,
                   const char* key,
                   const OrbitMenuItemId& id) {
  if (id.uid == 0) {
    properties.Set(key, id.string_uid);
  } else {
    properties.Set(key, id.uid);
  }
}

base::DictValue IdValue(const OrbitMenuItemId& id) {
  base::DictValue value;
  value.Set("extensionId", id.extension_id);
  if (id.uid == 0) {
    value.Set("stringUid", id.string_uid);
  } else {
    value.Set("uid", id.uid);
  }
  return value;
}

const char* TypeName(OrbitMenuItem::Type type) {
  switch (type) {
    case OrbitMenuItem::NORMAL:
      return "normal";
    case OrbitMenuItem::CHECKBOX:
      return "checkbox";
    case OrbitMenuItem::RADIO:
      return "radio";
    case OrbitMenuItem::SEPARATOR:
      return "separator";
  }
  return "normal";
}

bool GetStringList(const base::DictValue& dict,
                   const std::string& key,
                   std::vector<std::string>* out) {
  const base::Value* value = dict.Find(key);
  if (!value) {
    return true;
  }
  const base::ListValue* list = value->GetIfList();
  if (!list) {
    return false;
  }
  for (const base::Value& entry : *list) {
    if (!entry.is_string()) {
      return false;
    }
    out->push_back(entry.GetString());
  }
  return true;
}

// An empty pattern set means "no restriction", not "matches nothing" --
// context_menu_helpers.cc's ExtensionPatternMatch.
bool PatternMatch(const extensions::URLPatternSet& patterns, const GURL& url) {
  return patterns.is_empty() || patterns.MatchesURL(url);
}

bool ContextAndPatternMatch(const content::ContextMenuParams& params,
                            const OrbitMenuItem::ContextList& contexts,
                            const extensions::URLPatternSet& target_patterns) {
  const bool has_link = !params.link_url.is_empty();
  const bool has_selection = !params.selection_text.empty();

  if (contexts.Contains(OrbitMenuItem::ALL) ||
      (has_selection && contexts.Contains(OrbitMenuItem::SELECTION)) ||
      (params.is_editable && contexts.Contains(OrbitMenuItem::EDITABLE)) ||
      (params.is_subframe && contexts.Contains(OrbitMenuItem::FRAME))) {
    return true;
  }

  if (has_link && contexts.Contains(OrbitMenuItem::LINK) &&
      PatternMatch(target_patterns, params.link_url)) {
    return true;
  }

  switch (params.media_type) {
    case blink::mojom::ContextMenuDataMediaType::kImage:
      if (contexts.Contains(OrbitMenuItem::IMAGE) &&
          PatternMatch(target_patterns, params.src_url)) {
        return true;
      }
      break;
    case blink::mojom::ContextMenuDataMediaType::kVideo:
      if (contexts.Contains(OrbitMenuItem::VIDEO) &&
          PatternMatch(target_patterns, params.src_url)) {
        return true;
      }
      break;
    case blink::mojom::ContextMenuDataMediaType::kAudio:
      if (contexts.Contains(OrbitMenuItem::AUDIO) &&
          PatternMatch(target_patterns, params.src_url)) {
        return true;
      }
      break;
    default:
      break;
  }

  // PAGE is the least specific context, so it only applies when nothing more
  // specific does. FRAME stays folded into it for backwards compatibility.
  if (!has_link && !has_selection && !params.is_editable &&
      params.media_type == blink::mojom::ContextMenuDataMediaType::kNone &&
      contexts.Contains(OrbitMenuItem::PAGE)) {
    return true;
  }

  return false;
}

bool ItemMatchesParams(const content::ContextMenuParams& params,
                       const OrbitMenuItem* item) {
  if (!ContextAndPatternMatch(params, item->contexts(),
                              item->target_url_patterns())) {
    return false;
  }
  return PatternMatch(item->document_url_patterns(), params.frame_url);
}

void AddURLProperty(base::DictValue& dictionary,
                    const std::string& key,
                    const GURL& url) {
  if (!url.is_empty()) {
    dictionary.Set(key, url.possibly_invalid_spec());
  }
}

}  // namespace

OrbitMenuItemId::OrbitMenuItemId() = default;
OrbitMenuItemId::OrbitMenuItemId(const std::string& extension_id)
    : extension_id(extension_id) {}
OrbitMenuItemId::OrbitMenuItemId(const OrbitMenuItemId&) = default;
OrbitMenuItemId& OrbitMenuItemId::operator=(const OrbitMenuItemId&) = default;
OrbitMenuItemId::~OrbitMenuItemId() = default;

bool OrbitMenuItemId::operator<(const OrbitMenuItemId& other) const {
  return std::tie(extension_id, uid, string_uid) <
         std::tie(other.extension_id, other.uid, other.string_uid);
}

bool OrbitMenuItem::ContextList::Populate(const base::Value& value) {
  if (!value.is_int() || value.GetInt() < 0) {
    return false;
  }
  value_ = value.GetInt();
  return true;
}

OrbitMenuItem::OrbitMenuItem(const OrbitMenuItemId& id,
                             const std::string& title,
                             bool checked,
                             bool visible,
                             bool enabled,
                             Type type,
                             const ContextList& contexts)
    : id_(id),
      title_(title),
      type_(type),
      checked_(checked),
      visible_(visible),
      enabled_(enabled),
      contexts_(contexts) {}

OrbitMenuItem::~OrbitMenuItem() = default;

std::string OrbitMenuItem::TitleWithReplacement(const std::string& selection,
                                                size_t max_length) const {
  std::u16string result = base::UTF8ToUTF16(title_);
  base::ReplaceSubstringsAfterOffset(&result, 0, u"%s",
                                     base::UTF8ToUTF16(selection));
  if (result.length() > max_length) {
    result = gfx::TruncateString(result, max_length, gfx::WORD_BREAK);
  }
  return base::UTF16ToUTF8(result);
}

bool OrbitMenuItem::SetChecked(bool checked) {
  if (type_ != CHECKBOX && type_ != RADIO) {
    return false;
  }
  checked_ = checked;
  return true;
}

void OrbitMenuItem::AddChild(std::unique_ptr<OrbitMenuItem> item) {
  item->parent_id_ = std::make_unique<OrbitMenuItemId>(id_);
  children_.push_back(std::move(item));
}

std::unique_ptr<OrbitMenuItem> OrbitMenuItem::ReleaseChild(
    const OrbitMenuItemId& child_id,
    bool recursive) {
  for (auto i = children_.begin(); i != children_.end(); ++i) {
    if ((*i)->id() == child_id) {
      std::unique_ptr<OrbitMenuItem> child = std::move(*i);
      children_.erase(i);
      return child;
    }
    if (recursive) {
      if (std::unique_ptr<OrbitMenuItem> child =
              (*i)->ReleaseChild(child_id, recursive)) {
        return child;
      }
    }
  }
  return nullptr;
}

void OrbitMenuItem::GetFlattenedSubtree(List* list) {
  list->push_back(this);
  for (const auto& child : children_) {
    child->GetFlattenedSubtree(list);
  }
}

std::set<OrbitMenuItemId> OrbitMenuItem::RemoveAllDescendants() {
  std::set<OrbitMenuItemId> result;
  for (const auto& child : children_) {
    result.insert(child->id());
    std::set<OrbitMenuItemId> removed = child->RemoveAllDescendants();
    result.insert(removed.begin(), removed.end());
  }
  children_.clear();
  return result;
}

base::DictValue OrbitMenuItem::ToValue() const {
  base::DictValue value;
  value.Set(kStringUIDKey, id_.string_uid);
  value.Set(kTypeKey, type_);
  if (type_ != SEPARATOR) {
    value.Set(kTitleKey, title_);
  }
  if (type_ == CHECKBOX || type_ == RADIO) {
    value.Set(kCheckedKey, checked_);
  }
  value.Set(kEnabledKey, enabled_);
  value.Set(kVisibleKey, visible_);
  value.Set(kContextsKey, contexts_.ToValue());
  if (parent_id_) {
    value.Set(kParentUIDKey, parent_id_->string_uid);
  }
  value.Set(kDocumentURLPatternsKey, document_url_patterns_.ToValue());
  value.Set(kTargetURLPatternsKey, target_url_patterns_.ToValue());
  return value;
}

// static
std::unique_ptr<OrbitMenuItem> OrbitMenuItem::Populate(
    const std::string& extension_id,
    const base::DictValue& value,
    std::string* error) {
  OrbitMenuItemId id(extension_id);
  const std::string* string_uid = value.FindString(kStringUIDKey);
  if (!string_uid) {
    return nullptr;
  }
  id.string_uid = *string_uid;

  std::optional<int> type_int = value.FindInt(kTypeKey);
  if (!type_int.has_value()) {
    return nullptr;
  }
  Type type = static_cast<Type>(type_int.value());

  std::string title;
  if (type != SEPARATOR) {
    const std::string* specified_title = value.FindString(kTitleKey);
    if (!specified_title) {
      return nullptr;
    }
    title = *specified_title;
  }

  bool checked = false;
  if (type == CHECKBOX || type == RADIO) {
    std::optional<bool> specified_checked = value.FindBool(kCheckedKey);
    if (!specified_checked) {
      return nullptr;
    }
    checked = specified_checked.value();
  }

  bool visible = value.FindBool(kVisibleKey).value_or(true);

  std::optional<bool> specified_enabled = value.FindBool(kEnabledKey);
  if (!specified_enabled.has_value()) {
    return nullptr;
  }

  ContextList contexts;
  const base::Value* contexts_value = value.Find(kContextsKey);
  if (!contexts_value || !contexts.Populate(*contexts_value)) {
    return nullptr;
  }

  auto result = std::make_unique<OrbitMenuItem>(
      id, title, checked, visible, specified_enabled.value(), type, contexts);

  std::vector<std::string> document_url_patterns;
  if (!GetStringList(value, kDocumentURLPatternsKey, &document_url_patterns)) {
    return nullptr;
  }
  std::vector<std::string> target_url_patterns;
  if (!GetStringList(value, kTargetURLPatternsKey, &target_url_patterns)) {
    return nullptr;
  }
  if (!result->PopulateURLPatterns(&document_url_patterns, &target_url_patterns,
                                   error)) {
    return nullptr;
  }

  // Only recorded here; ReadFromStorage validates it by re-parenting the item.
  const base::Value* parent = value.Find(kParentUIDKey);
  if (parent) {
    if (!parent->is_string()) {
      return nullptr;
    }
    auto parent_id = std::make_unique<OrbitMenuItemId>(extension_id);
    parent_id->string_uid = parent->GetString();
    result->parent_id_ = std::move(parent_id);
  }
  return result;
}

bool OrbitMenuItem::PopulateURLPatterns(
    const std::vector<std::string>* document_url_patterns,
    const std::vector<std::string>* target_url_patterns,
    std::string* error) {
  if (document_url_patterns) {
    if (!document_url_patterns_.Populate(*document_url_patterns,
                                         URLPattern::SCHEME_ALL, true, error)) {
      return false;
    }
  }
  if (target_url_patterns) {
    if (!target_url_patterns_.Populate(*target_url_patterns,
                                       URLPattern::SCHEME_ALL, true, error)) {
      return false;
    }
  }
  return true;
}

// static
const char OrbitMenuManager::kOnContextMenus[] = "contextMenus";
// static
const char OrbitMenuManager::kOnClicked[] = "contextMenus.onClicked";

// static
OrbitMenuManager& OrbitMenuManager::GetInstance() {
  static base::NoDestructor<OrbitMenuManager> instance;
  return *instance;
}

OrbitMenuManager::OrbitMenuManager() = default;
OrbitMenuManager::~OrbitMenuManager() = default;

void OrbitMenuManager::StartObserving(
    content::BrowserContext* browser_context) {
  browser_context_ = browser_context;
  registry_observation_.Observe(
      extensions::ExtensionRegistry::Get(browser_context));
  if (extensions::StateStore* store = GetStateStore()) {
    store->RegisterKey(kContextMenusStorageKey);
  }
}

void OrbitMenuManager::StopObserving() {
  registry_observation_.Reset();
  write_tasks_.clear();
  items_by_id_.clear();
  context_items_.clear();
  browser_context_ = nullptr;
}

extensions::StateStore* OrbitMenuManager::GetStateStore() const {
  if (!browser_context_) {
    return nullptr;
  }
  extensions::ExtensionSystem* system =
      extensions::ExtensionSystem::Get(browser_context_);
  return system ? system->state_store() : nullptr;
}

std::set<std::string> OrbitMenuManager::ExtensionIds() const {
  std::set<std::string> ids;
  for (const auto& entry : context_items_) {
    ids.insert(entry.first);
  }
  return ids;
}

const OrbitMenuItem::OwnedList* OrbitMenuManager::MenuItems(
    const std::string& extension_id) const {
  auto i = context_items_.find(extension_id);
  return i == context_items_.end() ? nullptr : &i->second;
}

OrbitMenuItem::OwnedList::size_type OrbitMenuManager::MenuItemsSize(
    const std::string& extension_id) const {
  const OrbitMenuItem::OwnedList* list = MenuItems(extension_id);
  return list ? list->size() : 0;
}

bool OrbitMenuManager::AddContextItem(const extensions::Extension* extension,
                                      std::unique_ptr<OrbitMenuItem> item) {
  OrbitMenuItem* item_ptr = item.get();
  const std::string key = item->id().extension_id;
  if (key.empty() || items_by_id_.contains(item->id())) {
    return false;
  }

  context_items_[key].push_back(std::move(item));
  items_by_id_[item_ptr->id()] = item_ptr;

  if (item_ptr->type() == OrbitMenuItem::RADIO) {
    if (item_ptr->checked()) {
      RadioItemSelected(item_ptr);
    } else {
      SanitizeRadioListsInMenu(context_items_[key]);
    }
  }
  return true;
}

bool OrbitMenuManager::AddChildItem(const OrbitMenuItemId& parent_id,
                                    std::unique_ptr<OrbitMenuItem> child) {
  OrbitMenuItem* parent = GetItemById(parent_id);
  if (!parent || parent->type() != OrbitMenuItem::NORMAL ||
      parent->extension_id() != child->extension_id() ||
      items_by_id_.contains(child->id())) {
    return false;
  }
  OrbitMenuItem* child_ptr = child.get();
  parent->AddChild(std::move(child));
  items_by_id_[child_ptr->id()] = child_ptr;

  if (child_ptr->type() == OrbitMenuItem::RADIO) {
    SanitizeRadioListsInMenu(parent->children());
  }
  return true;
}

bool OrbitMenuManager::DescendantOf(OrbitMenuItem* item,
                                    const OrbitMenuItemId& ancestor_id) {
  OrbitMenuItemId* id = item->parent_id();
  while (id != nullptr) {
    if (*id == ancestor_id) {
      return true;
    }
    OrbitMenuItem* next = GetItemById(*id);
    if (!next) {
      return false;
    }
    id = next->parent_id();
  }
  return false;
}

bool OrbitMenuManager::ChangeParent(const OrbitMenuItemId& child_id,
                                    const OrbitMenuItemId* parent_id) {
  OrbitMenuItem* child_ptr = GetItemById(child_id);
  OrbitMenuItem* new_parent = parent_id ? GetItemById(*parent_id) : nullptr;
  if ((parent_id && child_id == *parent_id) || !child_ptr ||
      (!new_parent && parent_id != nullptr) ||
      (new_parent &&
       (DescendantOf(new_parent, child_id) ||
        child_ptr->extension_id() != new_parent->extension_id()))) {
    return false;
  }

  std::unique_ptr<OrbitMenuItem> child;
  OrbitMenuItemId* old_parent_id = child_ptr->parent_id();
  if (old_parent_id != nullptr) {
    OrbitMenuItem* old_parent = GetItemById(*old_parent_id);
    if (!old_parent) {
      return false;
    }
    child = old_parent->ReleaseChild(child_id, false);
    SanitizeRadioListsInMenu(old_parent->children());
  } else {
    auto i = context_items_.find(child_ptr->id().extension_id);
    if (i == context_items_.end()) {
      return false;
    }
    OrbitMenuItem::OwnedList& list = i->second;
    auto j = std::ranges::find(list, child_ptr, &std::unique_ptr<OrbitMenuItem>::get);
    if (j == list.end()) {
      return false;
    }
    child = std::move(*j);
    list.erase(j);
    SanitizeRadioListsInMenu(list);
  }
  if (!child) {
    return false;
  }

  if (new_parent) {
    new_parent->AddChild(std::move(child));
    SanitizeRadioListsInMenu(new_parent->children());
  } else {
    const std::string key = child_ptr->id().extension_id;
    context_items_[key].push_back(std::move(child));
    child_ptr->parent_id_.reset();
    SanitizeRadioListsInMenu(context_items_[key]);
  }
  return true;
}

bool OrbitMenuManager::RemoveContextMenuItem(const OrbitMenuItemId& id) {
  if (!items_by_id_.contains(id)) {
    return false;
  }
  const std::string extension_id = id.extension_id;
  auto i = context_items_.find(extension_id);
  if (i == context_items_.end()) {
    return false;
  }

  bool result = false;
  std::set<OrbitMenuItemId> items_removed;
  OrbitMenuItem::OwnedList& list = i->second;
  for (auto j = list.begin(); j < list.end(); ++j) {
    if ((*j)->id() == id) {
      items_removed = (*j)->RemoveAllDescendants();
      items_removed.insert(id);
      list.erase(j);
      result = true;
      SanitizeRadioListsInMenu(list);
      break;
    }
    std::unique_ptr<OrbitMenuItem> child =
        (*j)->ReleaseChild(id, /*recursive=*/true);
    if (child) {
      items_removed = child->RemoveAllDescendants();
      items_removed.insert(id);
      if (OrbitMenuItem* parent = GetItemById(*child->parent_id())) {
        SanitizeRadioListsInMenu(parent->children());
      }
      result = true;
      break;
    }
  }

  for (const OrbitMenuItemId& removed_id : items_removed) {
    items_by_id_.erase(removed_id);
  }
  if (list.empty()) {
    context_items_.erase(extension_id);
  }
  return result;
}

void OrbitMenuManager::RemoveAllContextItems(const std::string& extension_id) {
  auto i = context_items_.find(extension_id);
  if (i == context_items_.end()) {
    return;
  }
  for (const auto& item : i->second) {
    items_by_id_.erase(item->id());
    for (const OrbitMenuItemId& removed : item->RemoveAllDescendants()) {
      items_by_id_.erase(removed);
    }
  }
  context_items_.erase(extension_id);
}

OrbitMenuItem* OrbitMenuManager::GetItemById(const OrbitMenuItemId& id) const {
  auto i = items_by_id_.find(id);
  return i == items_by_id_.end() ? nullptr : i->second.get();
}

void OrbitMenuManager::RadioItemSelected(OrbitMenuItem* item) {
  const OrbitMenuItem::OwnedList* list = nullptr;
  if (item->parent_id()) {
    OrbitMenuItem* parent = GetItemById(*item->parent_id());
    if (!parent) {
      return;
    }
    list = &parent->children();
  } else {
    auto i = context_items_.find(item->id().extension_id);
    if (i == context_items_.end()) {
      return;
    }
    list = &i->second;
  }

  auto item_location = list->begin();
  for (; item_location != list->end(); ++item_location) {
    if (item_location->get() == item) {
      break;
    }
  }
  if (item_location == list->end()) {
    return;
  }

  // A radio "group" is a run of adjacent RADIO items, nothing more.
  if (item_location != list->begin()) {
    auto i = item_location;
    do {
      --i;
      if ((*i)->type() != OrbitMenuItem::RADIO) {
        break;
      }
      (*i)->SetChecked(false);
    } while (i != list->begin());
  }
  for (auto i = item_location + 1; i != list->end(); ++i) {
    if ((*i)->type() != OrbitMenuItem::RADIO) {
      break;
    }
    (*i)->SetChecked(false);
  }
}

void OrbitMenuManager::SanitizeRadioListsInMenu(
    const OrbitMenuItem::OwnedList& item_list) {
  auto i = item_list.begin();
  while (i != item_list.end()) {
    if ((*i)->type() != OrbitMenuItem::RADIO) {
      ++i;
      continue;
    }

    auto last_checked = item_list.end();
    OrbitMenuItem::OwnedList::const_iterator radio_run_iter;
    for (radio_run_iter = i; radio_run_iter != item_list.end();
         ++radio_run_iter) {
      if ((*radio_run_iter)->type() != OrbitMenuItem::RADIO) {
        break;
      }
      if ((*radio_run_iter)->checked()) {
        last_checked = radio_run_iter;
        (*radio_run_iter)->SetChecked(false);
      }
    }

    if (last_checked != item_list.end()) {
      (*last_checked)->SetChecked(true);
    } else {
      (*i)->SetChecked(true);
    }
    i = radio_run_iter;
  }
}

bool OrbitMenuManager::ItemUpdated(const OrbitMenuItemId& id) {
  if (!items_by_id_.contains(id)) {
    return false;
  }
  OrbitMenuItem* menu_item = GetItemById(id);

  if (!menu_item->parent_id()) {
    auto i = context_items_.find(menu_item->id().extension_id);
    if (i == context_items_.end()) {
      return false;
    }
    SanitizeRadioListsInMenu(i->second);
  } else {
    OrbitMenuItem* parent = GetItemById(*menu_item->parent_id());
    if (!parent) {
      return false;
    }
    SanitizeRadioListsInMenu(parent->children());
  }
  return true;
}

base::ListValue OrbitMenuManager::MatchingItemsValue(
    const OrbitMenuItem::List& items,
    const content::ContextMenuParams& params,
    const std::string& selection) const {
  base::ListValue result;
  for (OrbitMenuItem* item : items) {
    if (!item->visible() || !ItemMatchesParams(params, item)) {
      continue;
    }
    base::DictValue value;
    value.Set("id", IdValue(item->id()));
    value.Set("title",
              item->TitleWithReplacement(selection, kMaxItemTitleLength));
    value.Set("type", TypeName(item->type()));
    value.Set("checked", item->checked());
    value.Set("enabled", item->enabled());

    OrbitMenuItem::List children;
    for (const auto& child : item->children()) {
      children.push_back(child.get());
    }
    base::ListValue child_values =
        MatchingItemsValue(children, params, selection);
    if (!child_values.empty()) {
      value.Set("children", std::move(child_values));
    }
    result.Append(std::move(value));
  }
  return result;
}

base::ListValue OrbitMenuManager::MatchingItemsValue(
    const content::ContextMenuParams& params) const {
  base::ListValue result;
  if (!browser_context_) {
    return result;
  }
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(browser_context_);
  if (!registry) {
    return result;
  }

  std::u16string selection16 = gfx::TruncateString(
      params.selection_text, kMaxSelectionTextLength, gfx::WORD_BREAK);
  const std::string selection = base::UTF16ToUTF8(selection16);

  for (const auto& entry : context_items_) {
    const extensions::Extension* extension =
        registry->enabled_extensions().GetByID(entry.first);
    if (!extension) {
      continue;
    }
    OrbitMenuItem::List top_level;
    for (const auto& item : entry.second) {
      top_level.push_back(item.get());
    }
    base::ListValue items = MatchingItemsValue(top_level, params, selection);
    if (items.empty()) {
      continue;
    }
    base::DictValue group;
    group.Set("extensionId", entry.first);
    group.Set("extensionName", extension->name());
    group.Set("items", std::move(items));
    result.Append(std::move(group));
  }
  return result;
}

void OrbitMenuManager::ExecuteCommand(
    content::WebContents* web_contents,
    content::RenderFrameHost* render_frame_host,
    const content::ContextMenuParams& params,
    const OrbitMenuItemId& menu_item_id) {
  if (!browser_context_) {
    return;
  }
  extensions::EventRouter* event_router =
      extensions::EventRouter::Get(browser_context_);
  if (!event_router) {
    return;
  }

  OrbitMenuItem* item = GetItemById(menu_item_id);
  if (!item) {
    return;
  }

  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(browser_context_)
          ->enabled_extensions()
          .GetByID(item->extension_id());

  if (item->type() == OrbitMenuItem::RADIO) {
    RadioItemSelected(item);
  }

  base::DictValue properties;
  SetIdKeyValue(properties, "menuItemId", item->id());
  if (item->parent_id()) {
    SetIdKeyValue(properties, "parentMenuItemId", *item->parent_id());
  }

  switch (params.media_type) {
    case blink::mojom::ContextMenuDataMediaType::kImage:
      properties.Set("mediaType", "image");
      break;
    case blink::mojom::ContextMenuDataMediaType::kVideo:
      properties.Set("mediaType", "video");
      break;
    case blink::mojom::ContextMenuDataMediaType::kAudio:
      properties.Set("mediaType", "audio");
      break;
    default:
      break;
  }

  AddURLProperty(properties, "linkUrl", params.unfiltered_link_url);
  AddURLProperty(properties, "srcUrl", params.src_url);
  AddURLProperty(properties, "pageUrl", params.page_url);
  AddURLProperty(properties, "frameUrl", params.frame_url);

  if (!params.selection_text.empty()) {
    properties.Set("selectionText", params.selection_text);
  }
  properties.Set("editable", params.is_editable);

  base::ListValue args;
  args.Append(std::move(properties));

  if (extension) {
    if (web_contents) {
      if (render_frame_host) {
        const int frame_id =
            extensions::ExtensionApiFrameIdMap::GetFrameId(render_frame_host);
        if (frame_id != extensions::ExtensionApiFrameIdMap::kInvalidFrameId) {
          args[0].GetDict().Set("frameId", frame_id);
        }
      }
      // Deliberately unscrubbed, as upstream: the user chose to invoke this
      // extension on this page.
      const OrbitTabInfo* tab =
          OrbitTabRegistry::GetInstance().GetTabForWebContents(web_contents);
      args.Append(tab ? base::Value(OrbitTabRegistry::GetInstance()
                                        .CreateTabValue(*tab, extension,
                                                        /*force_full_access=*/true))
                      : base::Value(base::Value::Type::DICT));
    } else {
      args.Append(base::Value(base::Value::Type::DICT));
    }
  }

  if (item->type() == OrbitMenuItem::CHECKBOX ||
      item->type() == OrbitMenuItem::RADIO) {
    const bool was_checked = item->checked();
    args[0].GetDict().Set("wasChecked", was_checked);
    // A radio always ends up checked; a checkbox toggles.
    item->SetChecked(item->type() == OrbitMenuItem::RADIO || !was_checked);
    args[0].GetDict().Set("checked", item->checked());
    if (extension) {
      WriteToStorage(extension);
    }
  }

  if (item->extension_id().empty()) {
    return;
  }

  {
    auto args_cloned = args.Clone();
    auto event = std::make_unique<extensions::Event>(
        extensions::events::CONTEXT_MENUS, kOnContextMenus,
        std::move(args_cloned), browser_context_);
    event->user_gesture = extensions::EventRouter::UserGestureState::kEnabled;
    event_router->DispatchEventToExtension(item->extension_id(),
                                           std::move(event));
  }
  {
    auto event = std::make_unique<extensions::Event>(
        extensions::events::CONTEXT_MENUS_ON_CLICKED, kOnClicked,
        std::move(args), browser_context_);
    event->user_gesture = extensions::EventRouter::UserGestureState::kEnabled;
    event_router->DispatchEventToExtension(item->extension_id(),
                                           std::move(event));
  }
}

void OrbitMenuManager::WriteToStorage(const extensions::Extension* extension) {
  if (!extension || !extensions::BackgroundInfo::HasLazyContext(extension)) {
    return;
  }
  // Coalesced: create() is routinely called in a tight loop from onInstalled.
  write_tasks_[extension->id()].Start(
      FROM_HERE, base::Seconds(kWriteDelayInSeconds),
      base::BindOnce(&OrbitMenuManager::WriteToStorageInternal,
                     weak_ptr_factory_.GetWeakPtr(), extension->id()));
}

void OrbitMenuManager::WriteToStorageInternal(const std::string& extension_id) {
  write_tasks_.erase(extension_id);
  extensions::StateStore* store = GetStateStore();
  if (!store) {
    return;
  }

  base::ListValue all_items;
  if (const OrbitMenuItem::OwnedList* top_items = MenuItems(extension_id)) {
    for (const auto& item : *top_items) {
      OrbitMenuItem::List flattened;
      item->GetFlattenedSubtree(&flattened);
      for (OrbitMenuItem* entry : flattened) {
        all_items.Append(entry->ToValue());
      }
    }
  }
  store->SetExtensionValue(extension_id, kContextMenusStorageKey,
                           base::Value(std::move(all_items)));
}

void OrbitMenuManager::ReadFromStorage(const std::string& extension_id,
                                       std::optional<base::Value> value) {
  if (!browser_context_) {
    return;
  }
  const extensions::Extension* extension =
      extensions::ExtensionRegistry::Get(browser_context_)
          ->enabled_extensions()
          .GetByID(extension_id);
  if (!extension || !value || !value->is_list()) {
    return;
  }

  OrbitMenuItem::OwnedList items;
  for (const base::Value& element : value->GetList()) {
    if (!element.is_dict()) {
      continue;
    }
    std::unique_ptr<OrbitMenuItem> item =
        OrbitMenuItem::Populate(extension_id, element.GetDict(), nullptr);
    if (item) {
      items.push_back(std::move(item));
    }
  }
  if (items.size() > kMaxItemsPerExtension) {
    items.resize(kMaxItemsPerExtension);
  }

  // Parents were written before their children, so a child's parent is always
  // already back in the manager by the time it is read.
  for (auto& item : items) {
    if (item->parent_id()) {
      std::unique_ptr<OrbitMenuItemId> parent_id;
      parent_id.swap(item->parent_id_);
      AddChildItem(*parent_id, std::move(item));
    } else {
      AddContextItem(extension, std::move(item));
    }
  }
}

void OrbitMenuManager::OnExtensionLoaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension) {
  extensions::StateStore* store = GetStateStore();
  if (store && extensions::BackgroundInfo::HasLazyContext(extension)) {
    store->GetExtensionValue(
        extension->id(), kContextMenusStorageKey,
        base::BindOnce(&OrbitMenuManager::ReadFromStorage,
                       weak_ptr_factory_.GetWeakPtr(), extension->id()));
  }
}

void OrbitMenuManager::OnExtensionUnloaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    extensions::UnloadedExtensionReason reason) {
  RemoveAllContextItems(extension->id());
}

}  // namespace orbit
