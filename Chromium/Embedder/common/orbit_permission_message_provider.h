// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Real (not stubbed) extensions::PermissionMessageProvider. IsPrivilegeIncrease/
// GetAllPermissionIDs are ported verbatim (security load-bearing: get it wrong
// and an update silently gains permissions with no new prompt).

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_PERMISSION_MESSAGE_PROVIDER_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_PERMISSION_MESSAGE_PROVIDER_H_

#include "extensions/common/permissions/permission_message_provider.h"

namespace extensions {
class PermissionIDSet;
class PermissionSet;
}  // namespace extensions

namespace orbit {

class OrbitPermissionMessageProvider
    : public extensions::PermissionMessageProvider {
 public:
  OrbitPermissionMessageProvider();
  OrbitPermissionMessageProvider(const OrbitPermissionMessageProvider&) =
      delete;
  OrbitPermissionMessageProvider& operator=(
      const OrbitPermissionMessageProvider&) = delete;
  ~OrbitPermissionMessageProvider() override;

  // extensions::PermissionMessageProvider:
  extensions::PermissionMessages GetPermissionMessages(
      const extensions::PermissionIDSet& permissions) const override;
  bool IsPrivilegeIncrease(
      const extensions::PermissionSet& granted_permissions,
      const extensions::PermissionSet& requested_permissions,
      extensions::Manifest::Type extension_type) const override;
  extensions::PermissionIDSet GetAllPermissionIDs(
      const extensions::PermissionSet& permissions,
      extensions::Manifest::Type extension_type) const override;

 private:
  // Ported from ChromePermissionMessageProvider -- see the file comment.
  void AddAPIPermissions(const extensions::PermissionSet& permissions,
                          extensions::PermissionIDSet* permission_ids) const;
  void AddManifestPermissions(
      const extensions::PermissionSet& permissions,
      extensions::PermissionIDSet* permission_ids) const;
  void AddHostPermissions(const extensions::PermissionSet& permissions,
                           extensions::PermissionIDSet* permission_ids,
                           extensions::Manifest::Type extension_type) const;
  bool IsAPIOrManifestPrivilegeIncrease(
      const extensions::PermissionSet& granted_permissions,
      const extensions::PermissionSet& requested_permissions) const;
  bool IsHostPrivilegeIncrease(
      const extensions::PermissionSet& granted_permissions,
      const extensions::PermissionSet& requested_permissions,
      extensions::Manifest::Type extension_type) const;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_PERMISSION_MESSAGE_PROVIDER_H_
