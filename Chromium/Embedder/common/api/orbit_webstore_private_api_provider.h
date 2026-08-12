// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// extensions::ExtensionsAPIProvider for chrome.webstorePrivate -- a separate
// provider from OrbitExtensionsAPIProvider on purpose, with its own
// schema/feature files, though its compiled schema string is folded into
// the same shared :generated_api_json_strings bundle (a second bundle would
// collide on generated_schemas.{h,cc}).

#ifndef ORBIT_EMBEDDER_COMMON_API_ORBIT_WEBSTORE_PRIVATE_API_PROVIDER_H_
#define ORBIT_EMBEDDER_COMMON_API_ORBIT_WEBSTORE_PRIVATE_API_PROVIDER_H_

#include <string>
#include <string_view>

#include "extensions/common/extensions_api_provider.h"

namespace extensions {
class ManifestHandlerRegistry;
}  // namespace extensions

namespace orbit {

class OrbitWebstorePrivateAPIProvider : public extensions::ExtensionsAPIProvider {
 public:
  OrbitWebstorePrivateAPIProvider();
  OrbitWebstorePrivateAPIProvider(const OrbitWebstorePrivateAPIProvider&) = delete;
  OrbitWebstorePrivateAPIProvider& operator=(const OrbitWebstorePrivateAPIProvider&) = delete;
  ~OrbitWebstorePrivateAPIProvider() override;

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

#endif  // ORBIT_EMBEDDER_COMMON_API_ORBIT_WEBSTORE_PRIVATE_API_PROVIDER_H_
