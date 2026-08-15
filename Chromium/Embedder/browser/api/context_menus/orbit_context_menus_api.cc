// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_context_menus_api.h"

#include <memory>
#include <string>
#include <vector>

#include "base/strings/string_number_conversions.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/background_info.h"
#include "orbit/browser/orbit_menu_manager.h"

namespace orbit {

namespace {

// Verbatim from chrome/browser/extensions/context_menu_helpers.cc and
// context_menus_api.cc, so an extension's own error handling still matches.
constexpr char kIdRequiredError[] =
    "Extensions using event pages or Service Workers must pass an id parameter "
    "to chrome.contextMenus.create";
constexpr char kActionNotAllowedError[] =
    "Only extensions are allowed to use action contexts";
constexpr char kCannotFindItemError[] = "Cannot find menu item with id *";
constexpr char kCheckedError[] =
    "Only items with type \"radio\" or \"checkbox\" can be checked";
constexpr char kDuplicateIDError[] = "Cannot create item with duplicate id *";
constexpr char kGeneratedIdKey[] = "generatedId";
constexpr char kLauncherNotAllowedError[] =
    "Only packaged apps are allowed to use 'launcher' context";
constexpr char kOnclickDisallowedError[] =
    "Extensions using event pages or Service Workers cannot pass an onclick "
    "parameter to chrome.contextMenus.create. Instead, use the "
    "chrome.contextMenus.onClicked event.";
constexpr char kParentsMustBeNormalError[] =
    "Parent items must have type \"normal\"";
constexpr char kTitleNeededError[] =
    "All menu items except for separators must have a title";
constexpr char kTooManyMenuItems[] =
    "An extension can create a maximum of * menu items.";

std::string IDString(const OrbitMenuItemId& id) {
  return id.uid == 0 ? id.string_uid : base::NumberToString(id.uid);
}

// Fills the uid half of `id` from an integer-or-string API argument.
bool PopulateIdFromValue(const base::Value& value, OrbitMenuItemId* id) {
  if (value.is_int()) {
    id->uid = value.GetInt();
    return true;
  }
  if (value.is_string()) {
    id->string_uid = value.GetString();
    return true;
  }
  return false;
}

std::unique_ptr<OrbitMenuItemId> ParentIdFrom(const base::DictValue& properties,
                                              const std::string& extension_id) {
  const base::Value* parent = properties.Find("parentId");
  if (!parent) {
    return nullptr;
  }
  auto parent_id = std::make_unique<OrbitMenuItemId>(extension_id);
  if (!PopulateIdFromValue(*parent, parent_id.get())) {
    return nullptr;
  }
  return parent_id;
}

OrbitMenuItem* GetParent(const OrbitMenuItemId& parent_id,
                         const OrbitMenuManager& manager,
                         std::string* error) {
  OrbitMenuItem* parent = manager.GetItemById(parent_id);
  if (!parent) {
    *error = extensions::ErrorUtils::FormatErrorMessage(kCannotFindItemError,
                                                        IDString(parent_id));
    return nullptr;
  }
  if (parent->type() != OrbitMenuItem::NORMAL) {
    *error = kParentsMustBeNormalError;
    return nullptr;
  }
  return parent;
}

bool ParseContexts(const base::ListValue& raw,
                   OrbitMenuItem::ContextList* contexts,
                   std::string* error) {
  for (const base::Value& entry : raw) {
    if (!entry.is_string()) {
      *error = "Invalid value for contexts";
      return false;
    }
    const std::string& name = entry.GetString();
    if (name == "all") {
      contexts->Add(OrbitMenuItem::ALL);
    } else if (name == "page") {
      contexts->Add(OrbitMenuItem::PAGE);
    } else if (name == "selection") {
      contexts->Add(OrbitMenuItem::SELECTION);
    } else if (name == "link") {
      contexts->Add(OrbitMenuItem::LINK);
    } else if (name == "editable") {
      contexts->Add(OrbitMenuItem::EDITABLE);
    } else if (name == "image") {
      contexts->Add(OrbitMenuItem::IMAGE);
    } else if (name == "video") {
      contexts->Add(OrbitMenuItem::VIDEO);
    } else if (name == "audio") {
      contexts->Add(OrbitMenuItem::AUDIO);
    } else if (name == "frame") {
      contexts->Add(OrbitMenuItem::FRAME);
    } else if (name == "launcher") {
      contexts->Add(OrbitMenuItem::LAUNCHER);
    } else if (name == "browser_action") {
      contexts->Add(OrbitMenuItem::BROWSER_ACTION);
    } else if (name == "page_action") {
      contexts->Add(OrbitMenuItem::PAGE_ACTION);
    } else if (name == "action") {
      contexts->Add(OrbitMenuItem::ACTION);
    } else if (name == "tab") {
      contexts->Add(OrbitMenuItem::TAB);
    } else {
      *error = "Invalid value for contexts: " + name;
      return false;
    }
  }
  return true;
}

bool ParseType(const base::DictValue& properties,
               OrbitMenuItem::Type default_type,
               OrbitMenuItem::Type* out,
               std::string* error) {
  const std::string* type = properties.FindString("type");
  if (!type) {
    *out = default_type;
    return true;
  }
  if (*type == "normal") {
    *out = OrbitMenuItem::NORMAL;
  } else if (*type == "checkbox") {
    *out = OrbitMenuItem::CHECKBOX;
  } else if (*type == "radio") {
    *out = OrbitMenuItem::RADIO;
  } else if (*type == "separator") {
    *out = OrbitMenuItem::SEPARATOR;
  } else {
    *error = "Invalid value for type: " + *type;
    return false;
  }
  return true;
}

// Absent means "leave the existing patterns alone"; present-and-not-a-list is
// an error rather than an empty set.
bool ReadPatternList(const base::DictValue& properties,
                     const std::string& key,
                     std::vector<std::string>* out,
                     bool* present,
                     std::string* error) {
  const base::Value* value = properties.Find(key);
  if (!value) {
    *present = false;
    return true;
  }
  const base::ListValue* list = value->GetIfList();
  if (!list) {
    *error = "Invalid value for " + key;
    return false;
  }
  for (const base::Value& entry : *list) {
    if (!entry.is_string()) {
      *error = "Invalid value for " + key;
      return false;
    }
    out->push_back(entry.GetString());
  }
  *present = true;
  return true;
}

bool CreateMenuItem(const base::DictValue& create_properties,
                    const extensions::Extension* extension,
                    const OrbitMenuItemId& item_id,
                    std::string* error) {
  OrbitMenuManager& manager = OrbitMenuManager::GetInstance();

  if (manager.MenuItemsSize(item_id.extension_id) >=
      OrbitMenuManager::kMaxItemsPerExtension) {
    *error = extensions::ErrorUtils::FormatErrorMessage(
        kTooManyMenuItems,
        base::NumberToString(OrbitMenuManager::kMaxItemsPerExtension));
    return false;
  }
  if (manager.GetItemById(item_id)) {
    *error = extensions::ErrorUtils::FormatErrorMessage(kDuplicateIDError,
                                                        IDString(item_id));
    return false;
  }
  if (extensions::BackgroundInfo::HasLazyContext(extension) &&
      create_properties.Find("onclick")) {
    *error = kOnclickDisallowedError;
    return false;
  }

  OrbitMenuItem::ContextList contexts;
  if (const base::Value* raw = create_properties.Find("contexts")) {
    const base::ListValue* list = raw->GetIfList();
    if (!list || !ParseContexts(*list, &contexts, error)) {
      if (error->empty()) {
        *error = "Invalid value for contexts";
      }
      return false;
    }
  } else {
    contexts.Add(OrbitMenuItem::PAGE);
  }

  // Orbit hosts no platform apps at all, so 'launcher' is always refused --
  // the same answer upstream gives every ordinary extension.
  if (contexts.Contains(OrbitMenuItem::LAUNCHER)) {
    *error = kLauncherNotAllowedError;
    return false;
  }
  if ((contexts.Contains(OrbitMenuItem::BROWSER_ACTION) ||
       contexts.Contains(OrbitMenuItem::PAGE_ACTION) ||
       contexts.Contains(OrbitMenuItem::ACTION)) &&
      !extension->is_extension()) {
    *error = kActionNotAllowedError;
    return false;
  }

  std::string title;
  if (const std::string* raw = create_properties.FindString("title")) {
    title = *raw;
  }

  OrbitMenuItem::Type type = OrbitMenuItem::NORMAL;
  if (!ParseType(create_properties, OrbitMenuItem::NORMAL, &type, error)) {
    return false;
  }
  if (title.empty() && type != OrbitMenuItem::SEPARATOR) {
    *error = kTitleNeededError;
    return false;
  }

  const bool visible = create_properties.FindBool("visible").value_or(true);
  const bool checked = create_properties.FindBool("checked").value_or(false);
  const bool enabled = create_properties.FindBool("enabled").value_or(true);

  auto item = std::make_unique<OrbitMenuItem>(item_id, title, checked, visible,
                                              enabled, type, contexts);

  std::vector<std::string> document_url_patterns;
  std::vector<std::string> target_url_patterns;
  bool has_document_patterns = false;
  bool has_target_patterns = false;
  if (!ReadPatternList(create_properties, "documentUrlPatterns",
                       &document_url_patterns, &has_document_patterns, error) ||
      !ReadPatternList(create_properties, "targetUrlPatterns",
                       &target_url_patterns, &has_target_patterns, error)) {
    return false;
  }
  if (!item->PopulateURLPatterns(
          has_document_patterns ? &document_url_patterns : nullptr,
          has_target_patterns ? &target_url_patterns : nullptr, error)) {
    return false;
  }

  const base::Value* raw_parent = create_properties.Find("parentId");
  std::unique_ptr<OrbitMenuItemId> parent_id =
      ParentIdFrom(create_properties, item_id.extension_id);
  if (raw_parent && !parent_id) {
    *error = "Invalid value for parentId";
    return false;
  }

  bool success = false;
  if (parent_id) {
    OrbitMenuItem* parent = GetParent(*parent_id, manager, error);
    if (!parent) {
      return false;
    }
    success = manager.AddChildItem(parent->id(), std::move(item));
  } else {
    success = manager.AddContextItem(extension, std::move(item));
  }
  if (!success) {
    return false;
  }

  manager.WriteToStorage(extension);
  return true;
}

bool UpdateMenuItem(const base::DictValue& update_properties,
                    const extensions::Extension* extension,
                    const OrbitMenuItemId& item_id,
                    std::string* error) {
  OrbitMenuManager& manager = OrbitMenuManager::GetInstance();
  bool radio_item_updated = false;

  OrbitMenuItem* item = manager.GetItemById(item_id);
  if (!item || item->extension_id() != extension->id()) {
    *error = extensions::ErrorUtils::FormatErrorMessage(kCannotFindItemError,
                                                        IDString(item_id));
    return false;
  }

  OrbitMenuItem::Type type = item->type();
  if (!ParseType(update_properties, item->type(), &type, error)) {
    return false;
  }
  if (type != item->type()) {
    if (type == OrbitMenuItem::RADIO || item->type() == OrbitMenuItem::RADIO) {
      radio_item_updated = true;
    }
    item->set_type(type);
  }

  if (const std::string* title = update_properties.FindString("title")) {
    if (title->empty() && item->type() != OrbitMenuItem::SEPARATOR) {
      *error = kTitleNeededError;
      return false;
    }
    item->set_title(*title);
  }

  if (std::optional<bool> checked = update_properties.FindBool("checked")) {
    if (*checked && item->type() != OrbitMenuItem::CHECKBOX &&
        item->type() != OrbitMenuItem::RADIO) {
      *error = kCheckedError;
      return false;
    }
    // Unchecking a radio is a no-op: a radio run always has one selection.
    const bool should_toggle_checked =
        (item->type() == OrbitMenuItem::RADIO && *checked) ||
        item->type() == OrbitMenuItem::CHECKBOX;
    if (should_toggle_checked) {
      if (!item->SetChecked(*checked)) {
        *error = kCheckedError;
        return false;
      }
      radio_item_updated = true;
    }
  }

  if (std::optional<bool> visible = update_properties.FindBool("visible")) {
    item->set_visible(*visible);
  }
  if (std::optional<bool> enabled = update_properties.FindBool("enabled")) {
    item->set_enabled(*enabled);
  }

  if (const base::Value* raw = update_properties.Find("contexts")) {
    const base::ListValue* list = raw->GetIfList();
    OrbitMenuItem::ContextList contexts;
    if (!list || !ParseContexts(*list, &contexts, error)) {
      if (error->empty()) {
        *error = "Invalid value for contexts";
      }
      return false;
    }
    if (contexts.Contains(OrbitMenuItem::LAUNCHER)) {
      *error = kLauncherNotAllowedError;
      return false;
    }
    if (!(contexts == item->contexts())) {
      item->set_contexts(contexts);
    }
  }

  const base::Value* raw_parent = update_properties.Find("parentId");
  std::unique_ptr<OrbitMenuItemId> parent_id =
      ParentIdFrom(update_properties, item_id.extension_id);
  if (raw_parent && !raw_parent->is_none() && !parent_id) {
    *error = "Invalid value for parentId";
    return false;
  }
  if (parent_id) {
    OrbitMenuItem* parent = GetParent(*parent_id, manager, error);
    if (!parent || !manager.ChangeParent(item->id(), &parent->id())) {
      if (error->empty()) {
        *error = "Cannot set parent of menu item.";
      }
      return false;
    }
  }

  std::vector<std::string> document_url_patterns;
  std::vector<std::string> target_url_patterns;
  bool has_document_patterns = false;
  bool has_target_patterns = false;
  if (!ReadPatternList(update_properties, "documentUrlPatterns",
                       &document_url_patterns, &has_document_patterns, error) ||
      !ReadPatternList(update_properties, "targetUrlPatterns",
                       &target_url_patterns, &has_target_patterns, error)) {
    return false;
  }
  if (!item->PopulateURLPatterns(
          has_document_patterns ? &document_url_patterns : nullptr,
          has_target_patterns ? &target_url_patterns : nullptr, error)) {
    return false;
  }

  if (radio_item_updated && !manager.ItemUpdated(item->id())) {
    return false;
  }

  manager.WriteToStorage(extension);
  return true;
}

}  // namespace

ExtensionFunction::ResponseAction ContextMenusCreateFunction::Run() {
  if (!extension()) {
    return RespondNow(Error("contextMenus is only available to extensions"));
  }
  if (args().empty() || !args()[0].is_dict()) {
    return RespondNow(Error("contextMenus.create requires createProperties"));
  }
  const base::DictValue& properties = args()[0].GetDict();

  OrbitMenuItemId id(extension_id());
  if (const std::string* string_uid = properties.FindString("id")) {
    id.string_uid = *string_uid;
  } else {
    if (extensions::BackgroundInfo::HasLazyContext(extension())) {
      return RespondNow(Error(kIdRequiredError));
    }
    // Generated by the renderer's own context_menus_handlers.js so create()
    // can return the id synchronously; never sent by the extension.
    std::optional<int> generated = properties.FindInt(kGeneratedIdKey);
    if (!generated) {
      return RespondNow(Error(kIdRequiredError));
    }
    id.uid = *generated;
  }

  std::string error;
  if (!CreateMenuItem(properties, extension(), id, &error)) {
    return RespondNow(Error(error.empty() ? "Cannot create menu item." : error));
  }
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ContextMenusUpdateFunction::Run() {
  if (!extension()) {
    return RespondNow(Error("contextMenus is only available to extensions"));
  }
  if (args().size() < 2 || !args()[1].is_dict()) {
    return RespondNow(Error("contextMenus.update requires id and properties"));
  }
  OrbitMenuItemId item_id(extension_id());
  if (!PopulateIdFromValue(args()[0], &item_id)) {
    return RespondNow(Error("contextMenus.update requires a valid id"));
  }

  std::string error;
  if (!UpdateMenuItem(args()[1].GetDict(), extension(), item_id, &error)) {
    return RespondNow(Error(error.empty() ? "Cannot update menu item." : error));
  }
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ContextMenusRemoveFunction::Run() {
  if (args().empty()) {
    return RespondNow(Error("contextMenus.remove requires a menuItemId"));
  }
  OrbitMenuItemId id(extension_id());
  if (!PopulateIdFromValue(args()[0], &id)) {
    return RespondNow(Error("contextMenus.remove requires a valid menuItemId"));
  }

  OrbitMenuManager& manager = OrbitMenuManager::GetInstance();
  OrbitMenuItem* item = manager.GetItemById(id);
  // Per-extension isolation: one extension can never remove another's item.
  if (!item || item->extension_id() != extension_id()) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kCannotFindItemError, IDString(id))));
  }
  if (!manager.RemoveContextMenuItem(id)) {
    return RespondNow(Error("Cannot remove menu item."));
  }
  manager.WriteToStorage(extension());
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ContextMenusRemoveAllFunction::Run() {
  OrbitMenuManager& manager = OrbitMenuManager::GetInstance();
  manager.RemoveAllContextItems(extension_id());
  manager.WriteToStorage(extension());
  return RespondNow(NoArguments());
}

}  // namespace orbit
