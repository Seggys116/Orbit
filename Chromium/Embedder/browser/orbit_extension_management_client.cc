// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_management_client.h"

#include "extensions/common/url_pattern_set.h"
#include "url/gurl.h"

namespace orbit {

OrbitExtensionManagementClient::OrbitExtensionManagementClient() = default;
OrbitExtensionManagementClient::~OrbitExtensionManagementClient() = default;

bool OrbitExtensionManagementClient::UpdatesFromWebstore(
    const extensions::Extension& extension) {
  return true;
}

bool OrbitExtensionManagementClient::IsInstallationExplicitlyAllowed(
    const extensions::ExtensionId& id) {
  return true;
}

bool OrbitExtensionManagementClient::IsForceInstalledInLowTrustEnvironment(
    const extensions::Extension& extension) {
  return false;
}

const extensions::URLPatternSet&
OrbitExtensionManagementClient::GetPolicyBlockedHosts(
    const extensions::Extension* extension) {
  return extensions::URLPatternSet::Empty();
}

const extensions::URLPatternSet&
OrbitExtensionManagementClient::GetPolicyAllowedHosts(
    const extensions::Extension* extension) {
  return extensions::URLPatternSet::Empty();
}

bool OrbitExtensionManagementClient::UsesDefaultPolicyHostRestrictions(
    const extensions::Extension* extension) {
  return false;
}

bool OrbitExtensionManagementClient::BlocklistedByDefault() const {
  return false;
}

GURL OrbitExtensionManagementClient::GetEffectiveUpdateURL(
    const extensions::Extension& extension) {
  return GURL();
}

bool OrbitExtensionManagementClient::IsAllowedManifestType(
    extensions::Manifest::Type manifest_type,
    const std::string& extension_id) const {
  return true;
}

extensions::ManagedInstallationMode
OrbitExtensionManagementClient::GetInstallationMode(
    const extensions::Extension* extension) {
  return extensions::ManagedInstallationMode::kAllowed;
}

extensions::ManagedInstallationMode
OrbitExtensionManagementClient::GetInstallationMode(
    const extensions::ExtensionId& extension_id,
    const std::string& update_url) {
  return extensions::ManagedInstallationMode::kAllowed;
}

bool OrbitExtensionManagementClient::IsInstallationExplicitlyBlocked(
    const extensions::ExtensionId& id) {
  return false;
}

const std::string OrbitExtensionManagementClient::BlockedInstallMessage(
    const extensions::ExtensionId& id) {
  return std::string();
}

bool OrbitExtensionManagementClient::IsPermissionSetAllowed(
    const extensions::Extension* extension,
    const extensions::PermissionSet& perms) {
  return true;
}

bool OrbitExtensionManagementClient::IsPermissionSetAllowed(
    const extensions::ExtensionId& extension_id,
    const std::string& update_url,
    const extensions::PermissionSet& perms) {
  return true;
}

}  // namespace orbit
