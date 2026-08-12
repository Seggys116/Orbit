// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_user_script_registry.h"

#include "base/no_destructor.h"

namespace orbit {

// static
OrbitUserScriptRegistry& OrbitUserScriptRegistry::Get() {
  static base::NoDestructor<OrbitUserScriptRegistry> instance;
  return *instance;
}

OrbitUserScriptRegistry::OrbitUserScriptRegistry() = default;
OrbitUserScriptRegistry::~OrbitUserScriptRegistry() = default;

void OrbitUserScriptRegistry::SetGlobalScripts(
    std::vector<UserScriptSpec> scripts) {
  global_scripts_ = std::move(scripts);
  for (Observer& observer : observers_) {
    observer.OnGlobalUserScriptsChanged();
  }
}

void OrbitUserScriptRegistry::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OrbitUserScriptRegistry::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
}

}  // namespace orbit
