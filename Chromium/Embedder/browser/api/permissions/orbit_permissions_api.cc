// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_permissions_api.h"

#include <memory>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "base/values.h"
#include "content/public/common/url_constants.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/permissions/permissions_updater.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/permissions_parser.h"
#include "extensions/common/mojom/manifest.mojom-shared.h"
#include "extensions/common/permissions/api_permission.h"
#include "extensions/common/permissions/permission_message.h"
#include "extensions/common/permissions/permission_message_provider.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/common/permissions/permissions_data.h"
#include "extensions/common/permissions/permissions_info.h"
#include "extensions/common/url_pattern.h"
#include "extensions/common/url_pattern_set.h"
#include "extensions/common/user_script.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "url/url_constants.h"

namespace orbit {

namespace {

using extensions::APIPermission;
using extensions::APIPermissionInfo;
using extensions::APIPermissionSet;
using extensions::ErrorUtils;
using extensions::Extension;
using extensions::ExtensionPrefs;
using extensions::ManifestPermissionSet;
using extensions::PermissionMessageProvider;
using extensions::PermissionSet;
using extensions::PermissionsInfo;
using extensions::PermissionsParser;
using extensions::PermissionsUpdater;
using ::URLPattern;
using extensions::URLPatternSet;
using extensions::UserScript;

constexpr char kDelimiter[] = "|";
constexpr char kInvalidParameter[] = "Invalid argument for permission '*'.";
constexpr char kInvalidOrigin[] = "Invalid value for origin pattern *: *";
constexpr char kUnknownPermissionError[] =
    "'*' is not a recognized permission.";
constexpr char kCantRemoveRequiredPermissionsError[] =
    "You cannot remove required permissions.";
constexpr char kNotInManifestPermissionsError[] =
    "Only permissions specified in the manifest may be requested.";
constexpr char kUserGestureRequiredError[] =
    "This function must be called during a user gesture";
constexpr char kNoConsentSurfaceError[] =
    "Could not present the permission request to the user.";
constexpr char kNotWithheldError[] =
    "Only permissions that were withheld may be re-requested.";

std::unique_ptr<APIPermission> UnpackPermissionWithArguments(
    std::string_view permission_name,
    std::string_view permission_arg,
    const std::string& permission_str,
    std::string* error) {
  const APIPermissionInfo* permission_info =
      PermissionsInfo::GetInstance()->GetByName(std::string(permission_name));
  if (!permission_info) {
    *error = ErrorUtils::FormatErrorMessage(kUnknownPermissionError,
                                            std::string(permission_name));
    return nullptr;
  }

  std::optional<base::Value> permission_json = base::JSONReader::Read(
      permission_arg, base::JSON_PARSE_CHROMIUM_EXTENSIONS);
  if (!permission_json) {
    *error = ErrorUtils::FormatErrorMessage(kInvalidParameter, permission_str);
    return nullptr;
  }

  std::unique_ptr<APIPermission> permission =
      permission_info->CreateAPIPermission();
  if (!permission ||
      !permission->FromValue(&permission_json.value(), nullptr, nullptr)) {
    *error = ErrorUtils::FormatErrorMessage(kInvalidParameter, permission_str);
    return nullptr;
  }
  return permission;
}

// Ported from permissions_api_helpers.cc's UnpackAPIPermissions. The three-way
// partition (required/optional/unlisted) bounds every grant; unlisted_apis is always a hard failure.
bool UnpackAPIPermissions(const std::vector<std::string>& permissions_input,
                          const PermissionSet& required_permissions,
                          const PermissionSet& optional_permissions,
                          UnpackPermissionSetResult* result,
                          std::string* error) {
  PermissionsInfo* info = PermissionsInfo::GetInstance();
  APIPermissionSet apis;
  for (const std::string& permission_str : permissions_input) {
    size_t delimiter = permission_str.find(kDelimiter);
    if (delimiter != std::string::npos) {
      std::string_view permission_piece(permission_str);
      std::unique_ptr<APIPermission> permission = UnpackPermissionWithArguments(
          permission_piece.substr(0, delimiter),
          permission_piece.substr(delimiter + 1), permission_str, error);
      if (!permission) {
        return false;
      }
      apis.insert(std::move(permission));
      continue;
    }

    const APIPermissionInfo* permission_info = info->GetByName(permission_str);
    if (!permission_info) {
      *error = ErrorUtils::FormatErrorMessage(kUnknownPermissionError,
                                              permission_str);
      return false;
    }
    apis.insert(permission_info->id());
  }

  for (const APIPermission* api_permission : apis) {
    if (required_permissions.apis().count(api_permission->id())) {
      result->required_apis.insert(api_permission->Clone());
      continue;
    }
    if (!optional_permissions.apis().count(api_permission->id())) {
      result->unlisted_apis.insert(api_permission->Clone());
      continue;
    }
    result->optional_apis.insert(api_permission->Clone());
  }
  return true;
}

// Ported from permissions_api_helpers.cc's UnpackOriginPermissions. A pattern
// only reaches required_/optional_ if the manifest's own set contains it; anything wider is not grantable.
bool UnpackOriginPermissions(const std::vector<std::string>& origins_input,
                             const PermissionSet& required_permissions,
                             const PermissionSet& optional_permissions,
                             bool allow_file_access,
                             UnpackPermissionSetResult* result,
                             std::string* error) {
  const int user_script_schemes = UserScript::ValidUserScriptSchemes();
  const int explicit_schemes = Extension::kValidHostPermissionSchemes;

  auto filter_schemes = [allow_file_access](URLPattern* pattern) {
    int valid_schemes = pattern->valid_schemes();
    if (pattern->scheme() != content::kChromeUIScheme) {
      valid_schemes &= ~URLPattern::SCHEME_CHROMEUI;
    }
    if (!allow_file_access && pattern->scheme() != url::kFileScheme) {
      valid_schemes &= ~URLPattern::SCHEME_FILE;
    }
    if (valid_schemes != pattern->valid_schemes()) {
      pattern->SetValidSchemes(valid_schemes);
    }
  };

  for (const std::string& origin_str : origins_input) {
    URLPattern explicit_origin(explicit_schemes);
    URLPattern::ParseResult parse_result = explicit_origin.Parse(origin_str);
    if (parse_result != URLPattern::ParseResult::kSuccess) {
      *error = ErrorUtils::FormatErrorMessage(
          kInvalidOrigin, origin_str,
          URLPattern::GetParseResultString(parse_result));
      return false;
    }

    filter_schemes(&explicit_origin);

    if ((explicit_origin.valid_schemes() & URLPattern::SCHEME_FILE) &&
        !allow_file_access) {
      result->restricted_file_scheme_patterns.AddPattern(explicit_origin);
      continue;
    }

    bool used_origin = false;
    if (required_permissions.explicit_hosts().ContainsPattern(
            explicit_origin)) {
      used_origin = true;
      result->required_explicit_hosts.AddPattern(explicit_origin);
    } else if (optional_permissions.explicit_hosts().ContainsPattern(
                   explicit_origin)) {
      used_origin = true;
      result->optional_explicit_hosts.AddPattern(explicit_origin);
    }

    URLPattern scriptable_origin(user_script_schemes);
    if (scriptable_origin.Parse(origin_str) ==
        URLPattern::ParseResult::kSuccess) {
      filter_schemes(&scriptable_origin);
      if (required_permissions.scriptable_hosts().ContainsPattern(
              scriptable_origin)) {
        used_origin = true;
        result->required_scriptable_hosts.AddPattern(scriptable_origin);
      }
    }

    if (!used_origin) {
      result->unlisted_hosts.AddPattern(explicit_origin);
    }
  }
  return true;
}

// OrbitPermissionMessageProvider's table isn't exhaustive, so unlike upstream
// this never skips the prompt on empty warnings -- falls back to raw permission/host names instead.
base::ListValue WarningsFor(const PermissionSet& permissions,
                            const Extension& extension) {
  base::ListValue warnings;
  if (const PermissionMessageProvider* provider =
          PermissionMessageProvider::Get()) {
    for (const extensions::PermissionMessage& message :
         provider->GetPermissionMessages(
             provider->GetAllPermissionIDs(permissions, extension.GetType()))) {
      warnings.Append(base::UTF16ToUTF8(message.message()));
    }
  }
  if (!warnings.empty()) {
    return warnings;
  }
  for (const APIPermission* api : permissions.apis()) {
    warnings.Append(std::string(api->name()));
  }
  for (const URLPattern& pattern : permissions.effective_hosts()) {
    warnings.Append(pattern.GetAsString());
  }
  return warnings;
}

}  // namespace

PermissionsInput::PermissionsInput() = default;
PermissionsInput::~PermissionsInput() = default;

UnpackPermissionSetResult::UnpackPermissionSetResult() = default;
UnpackPermissionSetResult::~UnpackPermissionSetResult() = default;

base::DictValue PackPermissionSet(const PermissionSet& set) {
  base::DictValue packed;

  base::ListValue permissions;
  for (const APIPermission* api : set.apis()) {
    std::unique_ptr<base::Value> value = api->ToValue();
    if (!value) {
      permissions.Append(api->name());
      continue;
    }
    permissions.Append(std::string(api->name()) + kDelimiter +
                       base::WriteJson(*value).value_or(""));
  }
  packed.Set("permissions", std::move(permissions));

  base::ListValue origins;
  for (const URLPattern& pattern : set.effective_hosts()) {
    origins.Append(pattern.GetAsString());
  }
  packed.Set("origins", std::move(origins));

  return packed;
}

bool ParsePermissionsInput(const base::Value* value, PermissionsInput* out) {
  if (!value) {
    return false;
  }
  const base::DictValue* dict = value->GetIfDict();
  if (!dict) {
    return false;
  }

  auto read_list = [](const base::Value* list_value,
                      std::vector<std::string>* out_list) {
    if (!list_value || list_value->is_none()) {
      return true;
    }
    const base::ListValue* list = list_value->GetIfList();
    if (!list) {
      return false;
    }
    for (const base::Value& item : *list) {
      if (!item.is_string()) {
        return false;
      }
      out_list->push_back(item.GetString());
    }
    return true;
  };

  return read_list(dict->Find("permissions"), &out->permissions) &&
         read_list(dict->Find("origins"), &out->origins);
}

std::unique_ptr<UnpackPermissionSetResult> UnpackPermissionSet(
    const PermissionsInput& input,
    const PermissionSet& required_permissions,
    const PermissionSet& optional_permissions,
    bool has_file_access,
    std::string* error) {
  auto result = std::make_unique<UnpackPermissionSetResult>();
  if (!UnpackAPIPermissions(input.permissions, required_permissions,
                            optional_permissions, result.get(), error)) {
    return nullptr;
  }
  if (!UnpackOriginPermissions(input.origins, required_permissions,
                               optional_permissions, has_file_access,
                               result.get(), error)) {
    return nullptr;
  }
  return result;
}

ExtensionFunction::ResponseAction PermissionsGetAllFunction::Run() {
  return RespondNow(WithArguments(
      PackPermissionSet(extension()->permissions_data()->active_permissions())));
}

ExtensionFunction::ResponseAction PermissionsContainsFunction::Run() {
  PermissionsInput input;
  EXTENSION_FUNCTION_VALIDATE(args().size() == 1 &&
                              ParsePermissionsInput(&args()[0], &input));

  std::string error;
  std::unique_ptr<UnpackPermissionSetResult> unpack_result =
      UnpackPermissionSet(input,
                          PermissionsParser::GetRequiredPermissions(extension()),
                          PermissionsParser::GetOptionalPermissions(extension()),
                          ExtensionPrefs::Get(browser_context())
                              ->AllowFileAccess(extension()->id()),
                          &error);
  if (!unpack_result) {
    return RespondNow(Error(std::move(error)));
  }

  const PermissionSet& active =
      extension()->permissions_data()->active_permissions();

  const bool has_all_permissions =
      unpack_result->unlisted_apis.empty() &&
      unpack_result->unlisted_hosts.is_empty() &&
      unpack_result->restricted_file_scheme_patterns.is_empty() &&
      active.apis().Contains(unpack_result->optional_apis) &&
      active.apis().Contains(unpack_result->required_apis) &&
      active.explicit_hosts().Contains(
          unpack_result->optional_explicit_hosts) &&
      active.explicit_hosts().Contains(
          unpack_result->required_explicit_hosts) &&
      active.scriptable_hosts().Contains(
          unpack_result->required_scriptable_hosts);

  return RespondNow(WithArguments(has_all_permissions));
}

ExtensionFunction::ResponseAction PermissionsRemoveFunction::Run() {
  PermissionsInput input;
  EXTENSION_FUNCTION_VALIDATE(args().size() == 1 &&
                              ParsePermissionsInput(&args()[0], &input));

  std::string error;
  std::unique_ptr<UnpackPermissionSetResult> unpack_result =
      UnpackPermissionSet(input,
                          PermissionsParser::GetRequiredPermissions(extension()),
                          PermissionsParser::GetOptionalPermissions(extension()),
                          ExtensionPrefs::Get(browser_context())
                              ->AllowFileAccess(extension()->id()),
                          &error);
  if (!unpack_result) {
    return RespondNow(Error(std::move(error)));
  }

  if (!unpack_result->unlisted_apis.empty() ||
      !unpack_result->unlisted_hosts.is_empty()) {
    return RespondNow(Error(kNotInManifestPermissionsError));
  }

  if (!unpack_result->required_apis.empty() ||
      !unpack_result->required_explicit_hosts.is_empty() ||
      !unpack_result->required_scriptable_hosts.is_empty()) {
    return RespondNow(Error(kCantRemoveRequiredPermissionsError));
  }

  PermissionSet permissions(std::move(unpack_result->optional_apis),
                            ManifestPermissionSet(),
                            std::move(unpack_result->optional_explicit_hosts),
                            URLPatternSet());

  std::unique_ptr<const PermissionSet> permissions_to_revoke =
      PermissionSet::CreateIntersection(
          permissions, extension()->permissions_data()->active_permissions());

  PermissionsUpdater(browser_context())
      .RevokeOptionalPermissions(
          *extension(), *permissions_to_revoke,
          PermissionsUpdater::RemoveType::kSoft,
          base::BindOnce(&PermissionsRemoveFunction::Respond, this,
                         WithArguments(true)));
  return did_respond() ? AlreadyResponded() : RespondLater();
}

PermissionsRequestFunction::PermissionsRequestFunction() = default;
PermissionsRequestFunction::~PermissionsRequestFunction() = default;

ExtensionFunction::ResponseAction PermissionsRequestFunction::Run() {
  if (!user_gesture() &&
      extension()->location() != extensions::mojom::ManifestLocation::kComponent) {
    return RespondNow(Error(kUserGestureRequiredError));
  }

  PermissionsInput input;
  EXTENSION_FUNCTION_VALIDATE(args().size() == 1 &&
                              ParsePermissionsInput(&args()[0], &input));

  std::string error;
  std::unique_ptr<UnpackPermissionSetResult> unpack_result =
      UnpackPermissionSet(input,
                          PermissionsParser::GetRequiredPermissions(extension()),
                          PermissionsParser::GetOptionalPermissions(extension()),
                          ExtensionPrefs::Get(browser_context())
                              ->AllowFileAccess(extension()->id()),
                          &error);
  if (!unpack_result) {
    return RespondNow(Error(std::move(error)));
  }

  if (!unpack_result->unlisted_apis.empty() ||
      !unpack_result->unlisted_hosts.is_empty()) {
    return RespondNow(Error(kNotInManifestPermissionsError));
  }

  if (!unpack_result->restricted_file_scheme_patterns.is_empty()) {
    return RespondNow(Error(
        "Extension must have file access enabled to request '*'.",
        unpack_result->restricted_file_scheme_patterns.begin()->GetAsString()));
  }

  const PermissionSet& active =
      extension()->permissions_data()->active_permissions();

  requested_optional_ = std::make_unique<const PermissionSet>(
      std::move(unpack_result->optional_apis), ManifestPermissionSet(),
      std::move(unpack_result->optional_explicit_hosts), URLPatternSet());
  requested_optional_ =
      PermissionSet::CreateDifference(*requested_optional_, active);

  URLPatternSet explicit_hosts;
  for (const URLPattern& host : unpack_result->required_explicit_hosts) {
    if (!active.explicit_hosts().ContainsPattern(host)) {
      explicit_hosts.AddPattern(host);
    }
  }
  URLPatternSet scriptable_hosts;
  for (const URLPattern& host : unpack_result->required_scriptable_hosts) {
    if (!active.scriptable_hosts().ContainsPattern(host)) {
      scriptable_hosts.AddPattern(host);
    }
  }
  requested_withheld_ = std::make_unique<const PermissionSet>(
      APIPermissionSet(), ManifestPermissionSet(), std::move(explicit_hosts),
      std::move(scriptable_hosts));

  std::unique_ptr<const PermissionSet> total_new_permissions =
      PermissionSet::CreateUnion(*requested_withheld_, *requested_optional_);

  if (total_new_permissions->IsEmpty()) {
    return RespondNow(WithArguments(true));
  }

  // Upstream asserts this; Orbit checks it instead, since GrantRuntimePermissions
  // CHECKs the same condition and a set that's neither active nor withheld would crash the browser.
  if (!extension()->permissions_data()->withheld_permissions().Contains(
          *requested_withheld_)) {
    return RespondNow(Error(kNotWithheldError));
  }

  // Permissions previously granted (even if the extension later dropped them
  // via permissions.remove) are re-added without a second prompt, matching upstream.
  std::unique_ptr<const PermissionSet> granted_permissions =
      ExtensionPrefs::Get(browser_context())
          ->GetRuntimeGrantedPermissions(extension()->id());
  std::unique_ptr<const PermissionSet> already_granted_permissions =
      PermissionSet::CreateIntersection(*granted_permissions,
                                        *requested_optional_);
  total_new_permissions = PermissionSet::CreateDifference(
      *total_new_permissions, *already_granted_permissions);

  base::ListValue warnings = WarningsFor(*total_new_permissions, *extension());
  if (extension()->location() ==
      extensions::mojom::ManifestLocation::kComponent) {
    OnConsentDecision(true);
    return did_respond() ? AlreadyResponded() : RespondLater();
  }

  base::DictValue request = PackPermissionSet(*total_new_permissions);
  request.Set("extensionId", extension()->id());
  request.Set("extensionName", extension()->name());
  request.Set("warnings", std::move(warnings));

  if (!RequestPermissionsConsent(
          base::WriteJson(request).value_or(std::string()),
          base::BindOnce(&PermissionsRequestFunction::OnConsentDecision,
                         this))) {
    return RespondNow(Error(kNoConsentSurfaceError));
  }
  return did_respond() ? AlreadyResponded() : RespondLater();
}

bool PermissionsRequestFunction::ShouldKeepWorkerAliveIndefinitely() {
  return true;
}

void PermissionsRequestFunction::OnConsentDecision(bool approved) {
  if (!approved) {
    Respond(WithArguments(false));
    return;
  }

  PermissionsUpdater permissions_updater(browser_context());
  requesting_withheld_permissions_ = !requested_withheld_->IsEmpty();
  requesting_optional_permissions_ = !requested_optional_->IsEmpty();

  if (requesting_withheld_permissions_) {
    permissions_updater.GrantRuntimePermissions(
        *extension(), *requested_withheld_,
        base::BindOnce(&PermissionsRequestFunction::OnRuntimePermissionsGranted,
                       this));
  }
  if (requesting_optional_permissions_) {
    permissions_updater.GrantOptionalPermissions(
        *extension(), *requested_optional_,
        base::BindOnce(
            &PermissionsRequestFunction::OnOptionalPermissionsGranted, this));
  }

  if (!did_respond()) {
    RespondIfRequestsFinished();
  }
}

void PermissionsRequestFunction::OnRuntimePermissionsGranted() {
  requesting_withheld_permissions_ = false;
  RespondIfRequestsFinished();
}

void PermissionsRequestFunction::OnOptionalPermissionsGranted() {
  requesting_optional_permissions_ = false;
  RespondIfRequestsFinished();
}

void PermissionsRequestFunction::RespondIfRequestsFinished() {
  if (requesting_withheld_permissions_ || requesting_optional_permissions_) {
    return;
  }
  Respond(WithArguments(true));
}

}  // namespace orbit
