// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_preference_event_router.h"

#include <memory>
#include <utility>

#include "base/functional/bind.h"
#include "base/values.h"
#include "components/prefs/pref_service.h"
#include "components/user_prefs/user_prefs.h"
#include "content/public/browser/browser_context.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension.h"
#include "extensions/common/permissions/permissions_data.h"
#include "orbit/browser/api/preference/orbit_preference_api.h"

namespace orbit {

namespace {

constexpr char kLevelOfControlKey[] = "levelOfControl";
constexpr char kValueKey[] = "value";

PrefService* PrefsFor(content::BrowserContext* browser_context) {
  return browser_context ? user_prefs::UserPrefs::Get(browser_context)
                         : nullptr;
}

OrbitSearchSuggestEnabledCallback g_search_suggest_callback = nullptr;
void* g_search_suggest_opaque = nullptr;

}  // namespace

// static
OrbitPreferenceEventRouter& OrbitPreferenceEventRouter::GetInstance() {
  static base::NoDestructor<OrbitPreferenceEventRouter> instance;
  return *instance;
}

OrbitPreferenceEventRouter::OrbitPreferenceEventRouter() = default;
OrbitPreferenceEventRouter::~OrbitPreferenceEventRouter() = default;

void OrbitPreferenceEventRouter::SetSearchSuggestCallback(
    OrbitSearchSuggestEnabledCallback callback,
    void* opaque) {
  g_search_suggest_callback = callback;
  g_search_suggest_opaque = opaque;
}

void OrbitPreferenceEventRouter::StartObserving(
    content::BrowserContext* browser_context) {
  PrefService* prefs = PrefsFor(browser_context);
  if (!prefs) {
    return;
  }
  browser_context_ = browser_context;
  registrar_.Init(prefs);
  registrar_.Add(
      kSearchSuggestEnabledPref,
      base::BindRepeating(&OrbitPreferenceEventRouter::OnPrefChanged,
                          base::Unretained(this)));
}

void OrbitPreferenceEventRouter::StopObserving() {
  registrar_.RemoveAll();
  registrar_.Reset();
  browser_context_ = nullptr;
}

bool OrbitPreferenceEventRouter::GetSearchSuggestEnabled() const {
  const PrefService* prefs = browser_context_
                                 ? user_prefs::UserPrefs::Get(browser_context_)
                                 : nullptr;
  return prefs && prefs->GetBoolean(kSearchSuggestEnabledPref);
}

void OrbitPreferenceEventRouter::SetSearchSuggestEnabledUserValue(
    bool enabled) {
  PrefService* prefs = PrefsFor(browser_context_);
  if (!prefs) {
    return;
  }
  prefs->SetBoolean(kSearchSuggestEnabledPref, enabled);
}

void OrbitPreferenceEventRouter::OnPrefChanged(
    const std::string& browser_pref) {
  PrefService* prefs = PrefsFor(browser_context_);
  const PrefService::Preference* pref =
      prefs ? prefs->FindPreference(browser_pref) : nullptr;
  if (!pref) {
    return;
  }

  const OrbitPrefMapEntry* entry = FindOrbitPrefByBrowserName(browser_pref);
  if (!entry) {
    return;
  }

  if (browser_pref == kSearchSuggestEnabledPref && g_search_suggest_callback) {
    g_search_suggest_callback(g_search_suggest_opaque,
                              pref->GetValue()->GetBool());
  }

  extensions::EventRouter* router =
      extensions::EventRouter::Get(browser_context_);
  const std::string event_name = OrbitPrefChangeEventName(
      entry->extension_pref);
  if (!router || !router->HasEventListener(event_name)) {
    return;
  }

  // Per-extension rather than broadcast: levelOfControl is a different answer
  // for every extension, and it is injected into the payload itself.
  for (const scoped_refptr<const extensions::Extension>& extension :
       extensions::ExtensionRegistry::Get(browser_context_)
           ->enabled_extensions()) {
    if (!router->ExtensionHasEventListener(extension->id(), event_name) ||
        !extension->permissions_data()->HasAPIPermission(entry->permission)) {
      continue;
    }

    base::DictValue dict;
    dict.Set(kValueKey, pref->GetValue()->Clone());
    dict.Set(kLevelOfControlKey,
             OrbitLevelOfControl(browser_context_, extension->id(),
                                 browser_pref));
    base::ListValue args;
    args.Append(std::move(dict));

    router->DispatchEventToExtension(
        extension->id(),
        std::make_unique<extensions::Event>(
            extensions::events::TYPES_CHROME_SETTING_ON_CHANGE, event_name,
            std::move(args)));
  }
}

}  // namespace orbit
