// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_action_api.h"

#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/strings/string_number_conversions.h"
#include "content/public/common/color_parser.h"
#include "extensions/browser/extension_action.h"
#include "extensions/browser/extension_action_manager.h"
#include "extensions/browser/icon_util.h"
#include "extensions/browser/image_loader.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_resource.h"
#include "extensions/common/manifest_constants.h"
#include "orbit/browser/orbit_extension_action_dispatcher.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/gfx/geometry/size.h"
#include "ui/gfx/image/image.h"
#include "ui/gfx/image/image_skia.h"
#include "url/gurl.h"

namespace orbit {

namespace {

constexpr char kNoExtensionActionError[] =
    "This extension has no action specified.";
constexpr char kNoTabError[] = "No tab with id: ";
constexpr char kIconInvalidError[] = "Icon invalid.";
constexpr char kIconMissingError[] =
    "Either the path or imageData property must be specified.";

bool ParseColor(const base::Value& color_value, SkColor& color) {
  if (color_value.is_string()) {
    return content::ParseCssColorString(color_value.GetString(), &color);
  }
  if (!color_value.is_list()) {
    return false;
  }
  const base::ListValue& color_list = color_value.GetList();
  if (color_list.size() != 4) {
    return false;
  }
  for (const base::Value& component : color_list) {
    if (!component.is_int()) {
      return false;
    }
  }
  color = SkColorSetARGB(color_list[3].GetInt(), color_list[0].GetInt(),
                         color_list[1].GetInt(), color_list[2].GetInt());
  return true;
}

base::ListValue ColorToList(SkColor color) {
  base::ListValue list;
  list.Append(static_cast<int>(SkColorGetR(color)));
  list.Append(static_cast<int>(SkColorGetG(color)));
  list.Append(static_cast<int>(SkColorGetB(color)));
  list.Append(static_cast<int>(SkColorGetA(color)));
  return list;
}

// setIcon's `path`: a bare string or a {size -> path} dict. Upstream resolves
// this in chrome/-only renderer JS; Orbit loads it browser-side via extensions::ImageLoader instead.
std::vector<std::pair<std::string, int>> IconPathsFromDetails(
    const base::DictValue& details) {
  std::vector<std::pair<std::string, int>> paths;
  const base::Value* path_value = details.Find("path");
  if (!path_value) {
    return paths;
  }
  const int default_size = extensions::ExtensionAction::ActionIconSize();
  if (path_value->is_string()) {
    paths.emplace_back(path_value->GetString(), default_size);
    return paths;
  }
  const base::DictValue* path_dict = path_value->GetIfDict();
  if (!path_dict) {
    return paths;
  }
  for (const auto item : *path_dict) {
    if (!item.second.is_string()) {
      continue;
    }
    int size = default_size;
    if (!base::StringToInt(item.first, &size) || size <= 0) {
      size = default_size;
    }
    paths.emplace_back(item.second.GetString(), size);
  }
  return paths;
}

// `path` arrives as an absolute chrome-extension:// URL, not a relative path;
// it must be reduced to a resource path first or ImageLoader returns empty ("Icon invalid."). A URL naming a different extension yields nothing.
std::string ResourcePathFromIconPath(const std::string& path,
                                     const extensions::Extension& extension) {
  const GURL url(path);
  if (!url.is_valid() || !url.SchemeIs(extensions::kExtensionScheme)) {
    return path;
  }
  if (url.host() != extension.id()) {
    return std::string();
  }
  std::string_view resource_path = url.path();
  while (!resource_path.empty() && resource_path.front() == '/') {
    resource_path.remove_prefix(1);
  }
  return std::string(resource_path);
}

}  // namespace

ActionFunction::ActionFunction()
    : tab_id_(extensions::ExtensionAction::kDefaultTabId) {}

ActionFunction::~ActionFunction() = default;

ExtensionFunction::ResponseAction ActionFunction::Run() {
  extensions::ExtensionActionManager* manager =
      extensions::ExtensionActionManager::Get(browser_context());
  extension_action_ =
      manager ? manager->GetExtensionAction(*extension()) : nullptr;
  if (!extension_action_) {
    return RespondNow(Error(kNoExtensionActionError));
  }

  EXTENSION_FUNCTION_VALIDATE(ExtractDataFromArguments());

  if (tab_id_ != extensions::ExtensionAction::kDefaultTabId &&
      !OrbitTabRegistry::GetInstance().GetTab(tab_id_)) {
    return RespondNow(Error(kNoTabError + base::NumberToString(tab_id_)));
  }
  return RunExtensionAction();
}

bool ActionFunction::ExtractDataFromArguments() {
  if (args().empty()) {
    return true;
  }
  const base::Value& first_arg = args()[0];
  switch (first_arg.type()) {
    case base::Value::Type::INTEGER:
      tab_id_ = first_arg.GetInt();
      break;
    case base::Value::Type::DICT: {
      details_ = &first_arg.GetDict();
      if (const base::Value* tab_id_value = details_->Find("tabId")) {
        switch (tab_id_value->type()) {
          case base::Value::Type::NONE:
            return true;
          case base::Value::Type::INTEGER:
            tab_id_ = tab_id_value->GetInt();
            return true;
          default:
            return false;
        }
      }
      break;
    }
    case base::Value::Type::NONE:
      break;
    default:
      return false;
  }
  return true;
}

void ActionFunction::NotifyChange() {
  OrbitExtensionActionDispatcher::GetInstance().NotifyChange(browser_context(),
                                                             extension());
}

void ActionFunction::SetVisible(bool visible) {
  if (!extension_action_->SetIsVisible(tab_id_, visible)) {
    return;
  }
  NotifyChange();
}

ExtensionFunction::ResponseAction ActionEnableFunction::RunExtensionAction() {
  SetVisible(true);
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ActionDisableFunction::RunExtensionAction() {
  SetVisible(false);
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ActionIsEnabledFunction::RunExtensionAction() {
  return RespondNow(WithArguments(
      extension_action_->GetIsVisibleIgnoringDeclarative(tab_id_)));
}

ExtensionFunction::ResponseAction ActionSetTitleFunction::RunExtensionAction() {
  EXTENSION_FUNCTION_VALIDATE(details_);
  const std::string* title = details_->FindString("title");
  EXTENSION_FUNCTION_VALIDATE(title);
  extension_action_->SetTitle(tab_id_, *title);
  NotifyChange();
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ActionGetTitleFunction::RunExtensionAction() {
  return RespondNow(WithArguments(extension_action_->GetTitle(tab_id_)));
}

ExtensionFunction::ResponseAction ActionSetPopupFunction::RunExtensionAction() {
  EXTENSION_FUNCTION_VALIDATE(details_);
  const std::string* popup_string = details_->FindString("popup");
  EXTENSION_FUNCTION_VALIDATE(popup_string);

  GURL popup_url;
  // An empty string removes the explicitly set popup for this tab, which is
  // not the same as falling back to the manifest's own default_popup -- see
  // ExtensionAction::SetPopupUrl.
  if (!popup_string->empty()) {
    popup_url = extension()->ResolveExtensionURL(*popup_string);
    if (!popup_url.is_valid()) {
      return RespondNow(
          Error(extensions::manifest_errors::kInvalidExtensionPopupPath));
    }
  }
  extension_action_->SetPopupUrl(tab_id_, popup_url);
  NotifyChange();
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ActionGetPopupFunction::RunExtensionAction() {
  return RespondNow(
      WithArguments(extension_action_->GetPopupUrl(tab_id_).spec()));
}

ExtensionFunction::ResponseAction
ActionSetBadgeTextFunction::RunExtensionAction() {
  EXTENSION_FUNCTION_VALIDATE(details_);
  if (const std::string* badge_text = details_->FindString("text")) {
    extension_action_->SetBadgeText(tab_id_, *badge_text);
  } else {
    extension_action_->ClearBadgeText(tab_id_);
  }
  NotifyChange();
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction
ActionGetBadgeTextFunction::RunExtensionAction() {
  return RespondNow(
      WithArguments(extension_action_->GetDisplayBadgeText(tab_id_)));
}

ExtensionFunction::ResponseAction
ActionSetBadgeBackgroundColorFunction::RunExtensionAction() {
  EXTENSION_FUNCTION_VALIDATE(details_);
  const base::Value* color_value = details_->Find("color");
  EXTENSION_FUNCTION_VALIDATE(color_value);
  SkColor color = 0;
  if (!ParseColor(*color_value, color)) {
    return RespondNow(Error(extension_misc::kInvalidColorError));
  }
  extension_action_->SetBadgeBackgroundColor(tab_id_, color);
  NotifyChange();
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction
ActionGetBadgeBackgroundColorFunction::RunExtensionAction() {
  return RespondNow(WithArguments(
      ColorToList(extension_action_->GetBadgeBackgroundColor(tab_id_))));
}

ExtensionFunction::ResponseAction
ActionSetBadgeTextColorFunction::RunExtensionAction() {
  EXTENSION_FUNCTION_VALIDATE(details_);
  const base::Value* color_value = details_->Find("color");
  EXTENSION_FUNCTION_VALIDATE(color_value);
  SkColor color = 0;
  if (!ParseColor(*color_value, color)) {
    return RespondNow(Error(extension_misc::kInvalidColorError));
  }
  if (SkColorGetA(color) == SK_AlphaTRANSPARENT) {
    return RespondNow(Error(extension_misc::kInvalidColorError));
  }
  extension_action_->SetBadgeTextColor(tab_id_, color);
  NotifyChange();
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction
ActionGetBadgeTextColorFunction::RunExtensionAction() {
  return RespondNow(WithArguments(
      ColorToList(extension_action_->GetBadgeTextColor(tab_id_))));
}

ExtensionFunction::ResponseAction ActionSetIconFunction::RunExtensionAction() {
  EXTENSION_FUNCTION_VALIDATE(details_);

  // A canvas ImageData dictionary, if the caller built one itself.
  if (const base::DictValue* canvas_set = details_->FindDict("imageData")) {
    gfx::ImageSkia icon;
    const extensions::IconParseResult parse_result =
        extensions::ParseIconFromCanvasDictionary(*canvas_set, &icon);
    EXTENSION_FUNCTION_VALIDATE(parse_result ==
                                extensions::IconParseResult::kSuccess);
    if (icon.isNull()) {
      return RespondNow(Error(kIconInvalidError));
    }
    extension_action_->SetIcon(tab_id_, gfx::Image(icon));
    NotifyChange();
    return RespondNow(NoArguments());
  }

  const std::vector<std::pair<std::string, int>> paths =
      IconPathsFromDetails(*details_);
  if (!paths.empty()) {
    std::vector<extensions::ImageLoader::ImageRepresentation> representations;
    const int action_icon_size = extensions::ExtensionAction::ActionIconSize();
    for (const auto& [icon_path, size] : paths) {
      const std::string resource_path =
          ResourcePathFromIconPath(icon_path, *extension());
      if (resource_path.empty()) {
        continue;
      }
      representations.emplace_back(
          extension()->GetResource(resource_path),
          extensions::ImageLoader::ImageRepresentation::RESIZE_WHEN_LARGER,
          gfx::Size(size, size),
          static_cast<float>(size) / static_cast<float>(action_icon_size));
    }
    if (representations.empty()) {
      return RespondNow(Error(kIconInvalidError));
    }
    extensions::ImageLoader* loader =
        extensions::ImageLoader::Get(browser_context());
    if (!loader) {
      return RespondNow(Error(kIconInvalidError));
    }
    loader->LoadImagesAsync(
        extension(), representations,
        base::BindOnce(&ActionSetIconFunction::OnIconLoaded, this));
    // ImageLoader can answer synchronously when cached (common for repeated
    // setIcon calls); claiming RespondLater() after that would leave the call hanging.
    return did_respond() ? AlreadyResponded() : RespondLater();
  }

  // An obsolete iconIndex argument is accepted and ignored, matching upstream.
  if (details_->FindInt("iconIndex")) {
    return RespondNow(NoArguments());
  }
  return RespondNow(Error(kIconMissingError));
}

void ActionSetIconFunction::OnIconLoaded(const gfx::Image& image) {
  if (image.IsEmpty()) {
    Respond(Error(kIconInvalidError));
    return;
  }
  // Re-resolved rather than reused: the load hopped off the UI thread, and the
  // extension may have been unloaded (taking its ExtensionAction with it) meanwhile.
  extensions::ExtensionActionManager* manager =
      browser_context() ? extensions::ExtensionActionManager::Get(browser_context())
                        : nullptr;
  extensions::ExtensionAction* action =
      manager ? manager->GetExtensionAction(*extension()) : nullptr;
  if (!action) {
    Respond(Error(kNoExtensionActionError));
    return;
  }
  extension_action_ = action;
  action->SetIcon(tab_id_, image);
  NotifyChange();
  Respond(NoArguments());
}

}  // namespace orbit
