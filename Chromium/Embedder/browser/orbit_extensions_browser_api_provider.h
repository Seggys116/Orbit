// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Registers Orbit's own ExtensionFunctions (chrome.tabs, chrome.windows) by
// hand (RegisterFunction<T>()) rather than a generated_api_registration
// bundle; see orbit_tabs_api.h's file comment for why.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_BROWSER_API_PROVIDER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_BROWSER_API_PROVIDER_H_

#include "extensions/browser/extensions_browser_api_provider.h"

namespace orbit {

class OrbitExtensionsBrowserAPIProvider
    : public extensions::ExtensionsBrowserAPIProvider {
 public:
  OrbitExtensionsBrowserAPIProvider();
  OrbitExtensionsBrowserAPIProvider(const OrbitExtensionsBrowserAPIProvider&) =
      delete;
  OrbitExtensionsBrowserAPIProvider& operator=(
      const OrbitExtensionsBrowserAPIProvider&) = delete;
  ~OrbitExtensionsBrowserAPIProvider() override;

  void RegisterExtensionFunctions(ExtensionFunctionRegistry* registry) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_BROWSER_API_PROVIDER_H_
