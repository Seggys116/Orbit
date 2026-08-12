// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Registers chrome.webstorePrivate's ExtensionFunctions with ExtensionFunctionRegistry;
// kept separate from OrbitExtensionsBrowserAPIProvider so the two stay independently ownable.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_WEBSTORE_PRIVATE_BROWSER_API_PROVIDER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_WEBSTORE_PRIVATE_BROWSER_API_PROVIDER_H_

#include "extensions/browser/extensions_browser_api_provider.h"

namespace orbit {

class OrbitWebstorePrivateBrowserAPIProvider
    : public extensions::ExtensionsBrowserAPIProvider {
 public:
  OrbitWebstorePrivateBrowserAPIProvider();
  OrbitWebstorePrivateBrowserAPIProvider(
      const OrbitWebstorePrivateBrowserAPIProvider&) = delete;
  OrbitWebstorePrivateBrowserAPIProvider& operator=(
      const OrbitWebstorePrivateBrowserAPIProvider&) = delete;
  ~OrbitWebstorePrivateBrowserAPIProvider() override;

  void RegisterExtensionFunctions(ExtensionFunctionRegistry* registry) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_WEBSTORE_PRIVATE_BROWSER_API_PROVIDER_H_
