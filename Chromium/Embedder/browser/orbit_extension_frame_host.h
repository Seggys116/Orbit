// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Browser half of chrome.app's installState; the //extensions-core default
// answers with an empty string, so without this chrome.app.installState()
// resolves to nothing. Ported from chrome's ChromeExtensionFrameHost.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_FRAME_HOST_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_FRAME_HOST_H_

#include "extensions/browser/extension_frame_host.h"

namespace content {
class WebContents;
}

class GURL;

namespace orbit {

class OrbitExtensionFrameHost : public extensions::ExtensionFrameHost {
 public:
  explicit OrbitExtensionFrameHost(content::WebContents* web_contents);
  OrbitExtensionFrameHost(const OrbitExtensionFrameHost&) = delete;
  OrbitExtensionFrameHost& operator=(const OrbitExtensionFrameHost&) = delete;
  ~OrbitExtensionFrameHost() override;

  // extensions::mojom::LocalFrameHost:
  void GetAppInstallState(const GURL& requestor_url,
                          GetAppInstallStateCallback callback) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_FRAME_HOST_H_
