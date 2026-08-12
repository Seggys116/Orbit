// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extensions_renderer_client.h"

#include "content/public/common/isolated_world_ids.h"

namespace orbit {

OrbitExtensionsRendererClient::OrbitExtensionsRendererClient() {
  ExtensionsRendererClient::Set(this);
}

OrbitExtensionsRendererClient::~OrbitExtensionsRendererClient() {
  ExtensionsRendererClient::Set(nullptr);
}

bool OrbitExtensionsRendererClient::IsIncognitoProcess() const {
  // Orbit has no incognito/off-the-record profile yet.
  return false;
}

int OrbitExtensionsRendererClient::GetLowestIsolatedWorldId() const {
  // One past kOrbitIsolatedWorldId, which Boosts and the built-in user
  // scripts use. Extension worlds grow upward from here, unbounded.
  return content::ISOLATED_WORLD_ID_CONTENT_END + 1;
}

}  // namespace orbit
