// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// types.ChromeSetting.<pref>.onChange for both extensions and Swift, from one
// PrefChangeRegistrar, regardless of whether the change came from an extension or the user.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_PREFERENCE_EVENT_ROUTER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_PREFERENCE_EVENT_ROUTER_H_

#include <string>

#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "components/prefs/pref_change_registrar.h"
#include "orbit/bridge/orbit_bridge_api.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

class OrbitPreferenceEventRouter {
 public:
  static OrbitPreferenceEventRouter& GetInstance();

  OrbitPreferenceEventRouter(const OrbitPreferenceEventRouter&) = delete;
  OrbitPreferenceEventRouter& operator=(const OrbitPreferenceEventRouter&) =
      delete;

  void SetSearchSuggestCallback(OrbitSearchSuggestEnabledCallback callback,
                                void* opaque);

  // Called once the single OrbitBrowserContext exists, and again (with
  // StopObserving) as it goes away -- see OrbitBrowserMainParts.
  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();

  // The effective value, i.e. after any extension override. False if the
  // browser is not ready.
  bool GetSearchSuggestEnabled() const;

  // Writes the USER value, the one the Profile toggle in Settings owns. An
  // extension override still wins over it, exactly as in Chrome, so this can
  // change the stored value without changing the effective one.
  void SetSearchSuggestEnabledUserValue(bool enabled);

 private:
  friend class base::NoDestructor<OrbitPreferenceEventRouter>;

  OrbitPreferenceEventRouter();
  ~OrbitPreferenceEventRouter();

  void OnPrefChanged(const std::string& browser_pref);

  // The installed callback lives in a file-scope static in the .cc, not on this
  // class, matching Orbit's other Swift-installed callback pointers.
  raw_ptr<content::BrowserContext> browser_context_ = nullptr;
  PrefChangeRegistrar registrar_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_PREFERENCE_EVENT_ROUTER_H_
