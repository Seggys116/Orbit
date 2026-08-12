// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Process-global set of user scripts (single BrowserContext); every OrbitWebContentsHost
// observes it so a change re-pushes to every live frame of every open tab.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_USER_SCRIPT_REGISTRY_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_USER_SCRIPT_REGISTRY_H_

#include <vector>

#include "base/no_destructor.h"
#include "base/observer_list.h"
#include "orbit/common/orbit_user_script_spec.h"

namespace orbit {

class OrbitUserScriptRegistry {
 public:
  class Observer : public base::CheckedObserver {
   public:
    virtual void OnGlobalUserScriptsChanged() = 0;

   protected:
    ~Observer() override = default;
  };

  static OrbitUserScriptRegistry& Get();

  OrbitUserScriptRegistry(const OrbitUserScriptRegistry&) = delete;
  OrbitUserScriptRegistry& operator=(const OrbitUserScriptRegistry&) = delete;

  void SetGlobalScripts(std::vector<UserScriptSpec> scripts);
  const std::vector<UserScriptSpec>& global_scripts() const {
    return global_scripts_;
  }

  void AddObserver(Observer* observer);
  void RemoveObserver(Observer* observer);

 private:
  friend class base::NoDestructor<OrbitUserScriptRegistry>;

  OrbitUserScriptRegistry();
  ~OrbitUserScriptRegistry();

  std::vector<UserScriptSpec> global_scripts_;
  base::ObserverList<Observer> observers_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_USER_SCRIPT_REGISTRY_H_
