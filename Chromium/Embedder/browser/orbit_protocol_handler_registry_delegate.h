// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Modelled on ChromeProtocolHandlerRegistryDelegate, minus shell_integration (no
// per-scheme OS-default-handler support); the registry and prefs work fully without it.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_PROTOCOL_HANDLER_REGISTRY_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_PROTOCOL_HANDLER_REGISTRY_DELEGATE_H_

#include <string>

#include "components/custom_handlers/protocol_handler_registry.h"

namespace orbit {

class OrbitProtocolHandlerRegistryDelegate
    : public custom_handlers::ProtocolHandlerRegistry::Delegate {
 public:
  OrbitProtocolHandlerRegistryDelegate();
  OrbitProtocolHandlerRegistryDelegate(
      const OrbitProtocolHandlerRegistryDelegate&) = delete;
  OrbitProtocolHandlerRegistryDelegate& operator=(
      const OrbitProtocolHandlerRegistryDelegate&) = delete;
  ~OrbitProtocolHandlerRegistryDelegate() override;

  // custom_handlers::ProtocolHandlerRegistry::Delegate:
  void RegisterExternalHandler(const std::string& protocol) override;
  bool IsExternalHandlerRegistered(const std::string& protocol) override;
  void RegisterWithOSAsDefaultClient(const std::string& protocol,
                                     DefaultClientCallback callback) override;
  void CheckDefaultClientWithOS(const std::string& protocol,
                                DefaultClientCallback callback) override;
  bool ShouldRemoveHandlersNotInOS() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_PROTOCOL_HANDLER_REGISTRY_DELEGATE_H_
