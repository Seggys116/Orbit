// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_preference_api.h"

#include <string>

#include "base/strings/strcat.h"
#include "base/values.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/browser_context.h"
#include "components/user_prefs/user_prefs.h"
#include "extensions/browser/extension_prefs_helper.h"
#include "extensions/common/api/types.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/extension.h"
#include "extensions/common/permissions/permissions_data.h"

namespace orbit {

namespace {

using extensions::api::types::ChromeSettingScope;
using extensions::mojom::APIPermissionID;

constexpr char kIncognitoKey[] = "incognito";
constexpr char kLevelOfControlKey[] = "levelOfControl";
constexpr char kScopeKey[] = "scope";
constexpr char kValueKey[] = "value";

constexpr char kNotControllable[] = "not_controllable";
constexpr char kControlledByOtherExtensions[] = "controlled_by_other_extensions";
constexpr char kControllableByThisExtension[] = "controllable_by_this_extension";
constexpr char kControlledByThisExtension[] = "controlled_by_this_extension";

constexpr char kPermissionErrorMessage[] =
    "You do not have permission to access the preference '*'. Be sure to "
    "declare in your manifest what permissions you need.";
constexpr char kUnknownPreferenceError[] =
    "This browser does not have a preference named '*'.";
constexpr char kIncognitoUnsupportedError[] =
    "Orbit has no incognito context, so incognito preference scopes are not "
    "supported.";

constexpr OrbitPrefMapEntry kOrbitPrefMap[] = {
    {"searchSuggestEnabled", kSearchSuggestEnabledPref,
     APIPermissionID::kPrivacy},
};

PrefService* PrefsFor(content::BrowserContext* browser_context) {
  return browser_context ? user_prefs::UserPrefs::Get(browser_context)
                         : nullptr;
}

}  // namespace

const char* OrbitLevelOfControl(content::BrowserContext* browser_context,
                                const extensions::ExtensionId& extension_id,
                                const std::string& browser_pref) {
  PrefService* prefs = PrefsFor(browser_context);
  const PrefService::Preference* pref =
      prefs ? prefs->FindPreference(browser_pref) : nullptr;
  if (!pref || !pref->IsExtensionModifiable()) {
    return kNotControllable;
  }
  extensions::ExtensionPrefsHelper* helper =
      extensions::ExtensionPrefsHelper::Get(browser_context);
  if (!helper) {
    return kNotControllable;
  }
  if (helper->DoesExtensionControlPref(extension_id, browser_pref, nullptr)) {
    return kControlledByThisExtension;
  }
  if (helper->CanExtensionControlPref(extension_id, browser_pref,
                                      /*incognito=*/false)) {
    return kControllableByThisExtension;
  }
  return kControlledByOtherExtensions;
}

namespace {

// Orbit has one on-the-record BrowserContext, so every incognito scope is an
// honest error rather than a silently-downgraded write.
bool ScopeIsIncognito(ChromeSettingScope scope) {
  return scope == ChromeSettingScope::kIncognitoPersistent ||
         scope == ChromeSettingScope::kIncognitoSessionOnly;
}

}  // namespace

const OrbitPrefMapEntry* FindOrbitPrefByExtensionName(
    std::string_view extension_pref) {
  for (const OrbitPrefMapEntry& entry : kOrbitPrefMap) {
    if (extension_pref == entry.extension_pref) {
      return &entry;
    }
  }
  return nullptr;
}

const OrbitPrefMapEntry* FindOrbitPrefByBrowserName(
    std::string_view browser_pref) {
  for (const OrbitPrefMapEntry& entry : kOrbitPrefMap) {
    if (browser_pref == entry.browser_pref) {
      return &entry;
    }
  }
  return nullptr;
}

std::string OrbitPrefChangeEventName(std::string_view extension_pref) {
  return base::StrCat({"types.ChromeSetting.", extension_pref, ".onChange"});
}

ExtensionFunction::ResponseAction GetPreferenceFunction::Run() {
  EXTENSION_FUNCTION_VALIDATE(args().size() >= 2);
  EXTENSION_FUNCTION_VALIDATE(args()[0].is_string());
  EXTENSION_FUNCTION_VALIDATE(args()[1].is_dict());

  const std::string& pref_key = args()[0].GetString();
  if (args()[1].GetDict().FindBool(kIncognitoKey).value_or(false)) {
    return RespondNow(Error(kIncognitoUnsupportedError));
  }

  const OrbitPrefMapEntry* entry = FindOrbitPrefByExtensionName(pref_key);
  if (!entry) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kUnknownPreferenceError, pref_key)));
  }
  if (!extension()->permissions_data()->HasAPIPermission(entry->permission)) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kPermissionErrorMessage, pref_key)));
  }

  PrefService* prefs = PrefsFor(browser_context());
  const PrefService::Preference* pref =
      prefs ? prefs->FindPreference(entry->browser_pref) : nullptr;
  if (!pref) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kUnknownPreferenceError, pref_key)));
  }

  base::DictValue result;
  result.Set(kValueKey, pref->GetValue()->Clone());
  result.Set(kLevelOfControlKey,
             OrbitLevelOfControl(browser_context(), extension_id(),
                                 entry->browser_pref));
  return RespondNow(WithArguments(std::move(result)));
}

ExtensionFunction::ResponseAction SetPreferenceFunction::Run() {
  EXTENSION_FUNCTION_VALIDATE(args().size() >= 2);
  EXTENSION_FUNCTION_VALIDATE(args()[0].is_string());
  EXTENSION_FUNCTION_VALIDATE(args()[1].is_dict());

  const std::string& pref_key = args()[0].GetString();
  const base::DictValue& details = args()[1].GetDict();

  const base::Value* value = details.Find(kValueKey);
  EXTENSION_FUNCTION_VALIDATE(value);

  ChromeSettingScope scope = ChromeSettingScope::kRegular;
  if (const std::string* scope_str = details.FindString(kScopeKey)) {
    scope = extensions::api::types::ParseChromeSettingScope(*scope_str);
    EXTENSION_FUNCTION_VALIDATE(scope != ChromeSettingScope::kNone);
  }
  if (ScopeIsIncognito(scope)) {
    return RespondNow(Error(kIncognitoUnsupportedError));
  }

  const OrbitPrefMapEntry* entry = FindOrbitPrefByExtensionName(pref_key);
  if (!entry) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kUnknownPreferenceError, pref_key)));
  }
  if (!extension()->permissions_data()->HasAPIPermission(entry->permission)) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kPermissionErrorMessage, pref_key)));
  }

  PrefService* prefs = PrefsFor(browser_context());
  const PrefService::Preference* pref =
      prefs ? prefs->FindPreference(entry->browser_pref) : nullptr;
  if (!pref) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kUnknownPreferenceError, pref_key)));
  }
  EXTENSION_FUNCTION_VALIDATE(value->type() == pref->GetType());

  extensions::ExtensionPrefsHelper* helper =
      extensions::ExtensionPrefsHelper::Get(browser_context());
  EXTENSION_FUNCTION_VALIDATE(helper);
  helper->SetExtensionControlledPref(extension_id(), entry->browser_pref, scope,
                                     value->Clone());
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction ClearPreferenceFunction::Run() {
  EXTENSION_FUNCTION_VALIDATE(args().size() >= 2);
  EXTENSION_FUNCTION_VALIDATE(args()[0].is_string());
  EXTENSION_FUNCTION_VALIDATE(args()[1].is_dict());

  const std::string& pref_key = args()[0].GetString();
  const base::DictValue& details = args()[1].GetDict();

  ChromeSettingScope scope = ChromeSettingScope::kRegular;
  if (const std::string* scope_str = details.FindString(kScopeKey)) {
    scope = extensions::api::types::ParseChromeSettingScope(*scope_str);
    EXTENSION_FUNCTION_VALIDATE(scope != ChromeSettingScope::kNone);
  }
  if (ScopeIsIncognito(scope)) {
    return RespondNow(Error(kIncognitoUnsupportedError));
  }

  const OrbitPrefMapEntry* entry = FindOrbitPrefByExtensionName(pref_key);
  if (!entry) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kUnknownPreferenceError, pref_key)));
  }
  if (!extension()->permissions_data()->HasAPIPermission(entry->permission)) {
    return RespondNow(Error(extensions::ErrorUtils::FormatErrorMessage(
        kPermissionErrorMessage, pref_key)));
  }

  extensions::ExtensionPrefsHelper* helper =
      extensions::ExtensionPrefsHelper::Get(browser_context());
  EXTENSION_FUNCTION_VALIDATE(helper);
  helper->RemoveExtensionControlledPref(extension_id(), entry->browser_pref,
                                        scope);
  return RespondNow(NoArguments());
}

}  // namespace orbit
