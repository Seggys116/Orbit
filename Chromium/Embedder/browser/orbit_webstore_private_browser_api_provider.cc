// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_webstore_private_browser_api_provider.h"

#include "extensions/browser/extension_function_registry.h"
#include "orbit/browser/api/webstore_private/orbit_webstore_private_api.h"

namespace orbit {

OrbitWebstorePrivateBrowserAPIProvider::OrbitWebstorePrivateBrowserAPIProvider() = default;
OrbitWebstorePrivateBrowserAPIProvider::~OrbitWebstorePrivateBrowserAPIProvider() = default;

void OrbitWebstorePrivateBrowserAPIProvider::RegisterExtensionFunctions(
    ExtensionFunctionRegistry* registry) {
  registry->RegisterFunction<WebstorePrivateBeginInstallWithManifest3Function>();
  registry->RegisterFunction<WebstorePrivateCompleteInstallFunction>();
  registry->RegisterFunction<WebstorePrivateGetExtensionStatusFunction>();
  registry->RegisterFunction<WebstorePrivateGetStoreLoginFunction>();
  registry->RegisterFunction<WebstorePrivateSetStoreLoginFunction>();
  registry->RegisterFunction<WebstorePrivateGetWebGLStatusFunction>();
  registry->RegisterFunction<WebstorePrivateIsPendingCustodianApprovalFunction>();
  registry->RegisterFunction<WebstorePrivateGetReferrerChainFunction>();
  registry->RegisterFunction<WebstorePrivateGetFullChromeVersionFunction>();
}

}  // namespace orbit
