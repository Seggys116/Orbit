// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Only the two pure virtuals need overriding; everything else has a working
// default in extensions::ExtensionsRendererClient. Modelled on test_extensions_renderer_client.h.

#ifndef ORBIT_EMBEDDER_RENDERER_ORBIT_EXTENSIONS_RENDERER_CLIENT_H_
#define ORBIT_EMBEDDER_RENDERER_ORBIT_EXTENSIONS_RENDERER_CLIENT_H_

#include "extensions/renderer/extensions_renderer_client.h"

namespace orbit {

class OrbitExtensionsRendererClient : public extensions::ExtensionsRendererClient {
 public:
  OrbitExtensionsRendererClient();
  OrbitExtensionsRendererClient(const OrbitExtensionsRendererClient&) = delete;
  OrbitExtensionsRendererClient& operator=(const OrbitExtensionsRendererClient&) = delete;
  ~OrbitExtensionsRendererClient() override;

  // extensions::ExtensionsRendererClient:
  bool IsIncognitoProcess() const override;
  int GetLowestIsolatedWorldId() const override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_RENDERER_ORBIT_EXTENSIONS_RENDERER_CLIENT_H_
