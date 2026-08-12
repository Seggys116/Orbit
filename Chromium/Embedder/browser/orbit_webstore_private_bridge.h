// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Routes one chrome.webstorePrivate call from a native ExtensionFunction to Swift's
// WebStorePrivateBridge.handle(payload:contents:), replacing the deleted page-injected JS shim.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_WEBSTORE_PRIVATE_BRIDGE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_WEBSTORE_PRIVATE_BRIDGE_H_

#include <string>

#include "base/functional/callback_forward.h"
#include "base/values.h"

namespace content {
class WebContents;
}  // namespace content

namespace orbit {

// `method`/`args` match WebStorePrivateBridge.handle's expected shape for that method.
// Calls `callback` exactly once, async, with its {"ok":...} envelope or a synthesized failure.
void RequestFromNativeWebstorePrivateBridge(
    content::WebContents* web_contents,
    const std::string& method,
    base::ListValue args,
    base::OnceCallback<void(std::string result_json)> callback);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_WEBSTORE_PRIVATE_BRIDGE_H_
