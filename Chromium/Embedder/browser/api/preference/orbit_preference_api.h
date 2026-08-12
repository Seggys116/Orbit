// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// types.ChromeSetting.{get,set,clear}, ported from chrome/browser/extensions/api/preference/;
// renderer half and pref precedence machinery are already //extensions core. No incognito scopes or PrefTransformerInterface (all prefs are plain booleans).

#ifndef ORBIT_EMBEDDER_BROWSER_API_PREFERENCE_ORBIT_PREFERENCE_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_PREFERENCE_ORBIT_PREFERENCE_API_H_

#include <string>
#include <string_view>

#include "extensions/browser/extension_function.h"
#include "extensions/common/extension_id.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

// The one browser pref Orbit both stores and honours. Same string Chrome uses
// for the same setting.
inline constexpr char kSearchSuggestEnabledPref[] = "search.suggest_enabled";

struct OrbitPrefMapEntry {
  // The name an extension uses, i.e. privacy.json's own "value"[0].
  const char* extension_pref;
  const char* browser_pref;
  // Orbit draws no read/write distinction: every entry here is reachable only
  // through chrome.privacy, which is a single permission.
  extensions::mojom::APIPermissionID permission;
};

// Returns nullptr if `extension_pref` names no pref Orbit honours.
const OrbitPrefMapEntry* FindOrbitPrefByExtensionName(
    std::string_view extension_pref);
const OrbitPrefMapEntry* FindOrbitPrefByBrowserName(
    std::string_view browser_pref);

// "types.ChromeSetting.<extension pref>.onChange" -- the name
// extensions::ChromeSetting::GetOnChangeEvent builds on the renderer side.
std::string OrbitPrefChangeEventName(std::string_view extension_pref);

// One of types.LevelOfControl's string values, from this extension's point of
// view. Shared with OrbitPreferenceEventRouter for onChange payloads, matching upstream.
const char* OrbitLevelOfControl(content::BrowserContext* browser_context,
                                const extensions::ExtensionId& extension_id,
                                const std::string& browser_pref);

class GetPreferenceFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("types.ChromeSetting.get", TYPES_CHROMESETTING_GET)

 protected:
  ~GetPreferenceFunction() override = default;
  ResponseAction Run() override;
};

class SetPreferenceFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("types.ChromeSetting.set", TYPES_CHROMESETTING_SET)

 protected:
  ~SetPreferenceFunction() override = default;
  ResponseAction Run() override;
};

class ClearPreferenceFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("types.ChromeSetting.clear",
                             TYPES_CHROMESETTING_CLEAR)

 protected:
  ~ClearPreferenceFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_PREFERENCE_ORBIT_PREFERENCE_API_H_
