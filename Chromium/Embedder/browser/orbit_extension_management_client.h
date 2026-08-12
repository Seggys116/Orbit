// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Orbit has no enterprise policy engine, so every query answers with the
// unrestricted default. Modelled on TestExtensionManagementClient.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_MANAGEMENT_CLIENT_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_MANAGEMENT_CLIENT_H_

#include "extensions/browser/extension_management_client.h"

namespace orbit {

class OrbitExtensionManagementClient : public extensions::ExtensionManagementClient {
 public:
  OrbitExtensionManagementClient();
  OrbitExtensionManagementClient(const OrbitExtensionManagementClient&) = delete;
  OrbitExtensionManagementClient& operator=(const OrbitExtensionManagementClient&) = delete;
  ~OrbitExtensionManagementClient() override;

  // extensions::ExtensionManagementClient:
  bool UpdatesFromWebstore(const extensions::Extension& extension) override;
  bool IsInstallationExplicitlyAllowed(const extensions::ExtensionId& id) override;
  bool IsForceInstalledInLowTrustEnvironment(
      const extensions::Extension& extension) override;
  const extensions::URLPatternSet& GetPolicyBlockedHosts(
      const extensions::Extension* extension) override;
  const extensions::URLPatternSet& GetPolicyAllowedHosts(
      const extensions::Extension* extension) override;
  bool UsesDefaultPolicyHostRestrictions(
      const extensions::Extension* extension) override;
  bool BlocklistedByDefault() const override;
  GURL GetEffectiveUpdateURL(const extensions::Extension& extension) override;
  bool IsAllowedManifestType(extensions::Manifest::Type manifest_type,
                             const std::string& extension_id) const override;
  extensions::ManagedInstallationMode GetInstallationMode(
      const extensions::Extension* extension) override;
  extensions::ManagedInstallationMode GetInstallationMode(
      const extensions::ExtensionId& extension_id,
      const std::string& update_url) override;
  bool IsInstallationExplicitlyBlocked(const extensions::ExtensionId& id) override;
  const std::string BlockedInstallMessage(const extensions::ExtensionId& id) override;
  bool IsPermissionSetAllowed(const extensions::Extension* extension,
                              const extensions::PermissionSet& perms) override;
  bool IsPermissionSetAllowed(const extensions::ExtensionId& extension_id,
                              const std::string& update_url,
                              const extensions::PermissionSet& perms) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_MANAGEMENT_CLIENT_H_
