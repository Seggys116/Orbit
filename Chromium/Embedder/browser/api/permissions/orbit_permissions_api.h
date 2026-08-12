// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.permissions ported from chrome/-layer only; PermissionsUpdater/Parser/
// ExtensionPrefs are already wired in //extensions. No addHostAccessRequest/removeHostAccessRequest or enterprise policy gate.

#ifndef ORBIT_EMBEDDER_BROWSER_API_PERMISSIONS_ORBIT_PERMISSIONS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_PERMISSIONS_ORBIT_PERMISSIONS_API_H_

#include <memory>
#include <string>
#include <vector>

#include "base/values.h"
#include "extensions/browser/extension_function.h"
#include "extensions/common/permissions/api_permission_set.h"
#include "extensions/common/url_pattern_set.h"

namespace extensions {
class PermissionSet;
}  // namespace extensions

namespace orbit {

// Parsed chrome.permissions.Permissions argument. Hand-parsed since Orbit's
// schema bundle doesn't compile json_schema_compiler Params structs (see common/api/BUILD.gn).
struct PermissionsInput {
  PermissionsInput();
  PermissionsInput(const PermissionsInput&) = delete;
  PermissionsInput& operator=(const PermissionsInput&) = delete;
  ~PermissionsInput();

  std::vector<std::string> permissions;
  std::vector<std::string> origins;
};

// Ported from permissions_api_helpers.h. This partitioning is the whole security
// boundary: unlisted_apis/unlisted_hosts were never declared and can never be granted.
struct UnpackPermissionSetResult {
  UnpackPermissionSetResult();
  UnpackPermissionSetResult(const UnpackPermissionSetResult&) = delete;
  UnpackPermissionSetResult& operator=(const UnpackPermissionSetResult&) =
      delete;
  ~UnpackPermissionSetResult();

  extensions::APIPermissionSet required_apis;
  extensions::URLPatternSet required_explicit_hosts;
  extensions::URLPatternSet required_scriptable_hosts;

  extensions::APIPermissionSet optional_apis;
  extensions::URLPatternSet optional_explicit_hosts;

  extensions::APIPermissionSet unlisted_apis;
  extensions::URLPatternSet unlisted_hosts;

  // file:-scheme patterns ungrantable due to no file access. Held apart so
  // they can neither be requested nor reported as contained.
  extensions::URLPatternSet restricted_file_scheme_patterns;
};

base::DictValue PackPermissionSet(const extensions::PermissionSet& set);

// Reads args()[0] into `out`. False if it is not a Permissions object, or if
// either list holds a non-string.
bool ParsePermissionsInput(const base::Value* value, PermissionsInput* out);

std::unique_ptr<UnpackPermissionSetResult> UnpackPermissionSet(
    const PermissionsInput& input,
    const extensions::PermissionSet& required_permissions,
    const extensions::PermissionSet& optional_permissions,
    bool has_file_access,
    std::string* error);

class PermissionsGetAllFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("permissions.getAll", PERMISSIONS_GETALL)

 protected:
  ~PermissionsGetAllFunction() override = default;
  ResponseAction Run() override;
};

class PermissionsContainsFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("permissions.contains", PERMISSIONS_CONTAINS)

 protected:
  ~PermissionsContainsFunction() override = default;
  ResponseAction Run() override;
};

class PermissionsRemoveFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("permissions.remove", PERMISSIONS_REMOVE)

 protected:
  ~PermissionsRemoveFunction() override = default;
  ResponseAction Run() override;
};

class PermissionsRequestFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("permissions.request", PERMISSIONS_REQUEST)

  PermissionsRequestFunction();
  PermissionsRequestFunction(const PermissionsRequestFunction&) = delete;
  PermissionsRequestFunction& operator=(const PermissionsRequestFunction&) =
      delete;

 protected:
  ~PermissionsRequestFunction() override;
  ResponseAction Run() override;
  bool ShouldKeepWorkerAliveIndefinitely() override;

 private:
  void OnConsentDecision(bool approved);
  void OnRuntimePermissionsGranted();
  void OnOptionalPermissionsGranted();
  void RespondIfRequestsFinished();

  std::unique_ptr<const extensions::PermissionSet> requested_withheld_;
  std::unique_ptr<const extensions::PermissionSet> requested_optional_;

  bool requesting_withheld_permissions_ = false;
  bool requesting_optional_permissions_ = false;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_PERMISSIONS_ORBIT_PERMISSIONS_API_H_
