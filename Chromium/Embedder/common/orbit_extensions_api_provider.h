// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Orbit's own extensions::ExtensionsAPIProvider, registered alongside
// extensions::CoreExtensionsAPIProvider in OrbitExtensionsClient. Supplies
// the chrome-layer APIs //extensions itself doesn't implement: chrome.tabs
// and chrome.windows.

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_EXTENSIONS_API_PROVIDER_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_EXTENSIONS_API_PROVIDER_H_

#include <string>
#include <string_view>

#include "extensions/common/extensions_api_provider.h"

namespace extensions {
class ManifestHandlerRegistry;
}  // namespace extensions

namespace orbit {

class OrbitExtensionsAPIProvider : public extensions::ExtensionsAPIProvider {
 public:
  OrbitExtensionsAPIProvider();
  OrbitExtensionsAPIProvider(const OrbitExtensionsAPIProvider&) = delete;
  OrbitExtensionsAPIProvider& operator=(const OrbitExtensionsAPIProvider&) =
      delete;
  ~OrbitExtensionsAPIProvider() override;

  // extensions::ExtensionsAPIProvider:
  void AddAPIFeatures(extensions::FeatureProvider* provider) override;
  void AddManifestFeatures(extensions::FeatureProvider* provider) override;
  void AddPermissionFeatures(extensions::FeatureProvider* provider) override;
  void AddBehaviorFeatures(extensions::FeatureProvider* provider) override;
  void AddAPIJSONSources(
      extensions::JSONFeatureProviderSource* json_source) override;
  bool IsAPISchemaGenerated(const std::string& name) override;
  std::string_view GetAPISchema(const std::string& name) override;
  void RegisterPermissions(
      extensions::PermissionsInfo* permissions_info) override;
  void RegisterManifestHandlers(
      extensions::ManifestHandlerRegistry* registry) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_EXTENSIONS_API_PROVIDER_H_
