// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_protocol_handler_registry_delegate.h"

#include <utility>

#include "content/public/browser/child_process_security_policy.h"

namespace orbit {

OrbitProtocolHandlerRegistryDelegate::OrbitProtocolHandlerRegistryDelegate() =
    default;
OrbitProtocolHandlerRegistryDelegate::
    ~OrbitProtocolHandlerRegistryDelegate() = default;

void OrbitProtocolHandlerRegistryDelegate::RegisterExternalHandler(
    const std::string& protocol) {
  // Same as ChromeProtocolHandlerRegistryDelegate: a registered handler's
  // scheme must be web-safe for renderers to navigate to translated URLs.
  content::ChildProcessSecurityPolicy* policy =
      content::ChildProcessSecurityPolicy::GetInstance();
  if (!policy->IsWebSafeScheme(protocol)) {
    policy->RegisterWebSafeScheme(protocol);
  }
}

bool OrbitProtocolHandlerRegistryDelegate::IsExternalHandlerRegistered(
    const std::string& protocol) {
  // Orbit keeps no OS-external protocol handler registry of its own (no
  // ProfileIOData equivalent); the ProtocolHandlerRegistry's own storage is
  // the only source of truth.
  return false;
}

void OrbitProtocolHandlerRegistryDelegate::RegisterWithOSAsDefaultClient(
    const std::string& protocol,
    DefaultClientCallback callback) {
  // Orbit has no per-scheme "set as OS default handler" integration; answer false
  // rather than faking success.
  std::move(callback).Run(false);
}

void OrbitProtocolHandlerRegistryDelegate::CheckDefaultClientWithOS(
    const std::string& protocol,
    DefaultClientCallback callback) {
  std::move(callback).Run(false);
}

bool OrbitProtocolHandlerRegistryDelegate::ShouldRemoveHandlersNotInOS() {
  // RegisterWithOSAsDefaultClient/CheckDefaultClientWithOS never consult the OS, so
  // there is no OS-registration state to diff handlers against (same as Chrome on Linux).
  return false;
}

}  // namespace orbit
