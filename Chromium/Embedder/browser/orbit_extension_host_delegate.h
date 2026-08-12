// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Backs extensions::ExtensionHost (background pages/extension views; MV3
// service worker backgrounds use ServiceWorkerTaskQueue instead). Orbit
// doesn't yet support extension tabs/popups or media devices, so those
// honestly no-op/deny.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_HOST_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_HOST_DELEGATE_H_

#include "extensions/browser/extension_host_delegate.h"

namespace orbit {

class OrbitExtensionHostDelegate : public extensions::ExtensionHostDelegate {
 public:
  OrbitExtensionHostDelegate();
  OrbitExtensionHostDelegate(const OrbitExtensionHostDelegate&) = delete;
  OrbitExtensionHostDelegate& operator=(const OrbitExtensionHostDelegate&) = delete;
  ~OrbitExtensionHostDelegate() override;

  // extensions::ExtensionHostDelegate:
  void OnExtensionHostCreated(content::WebContents* web_contents) override;
  void CreateTab(std::unique_ptr<content::WebContents> web_contents,
                const GURL& target_url,
                const extensions::ExtensionId& extension_id,
                WindowOpenDisposition disposition,
                const blink::mojom::WindowFeatures& window_features,
                bool user_gesture) override;
  void ProcessMediaAccessRequest(content::WebContents* web_contents,
                                 const content::MediaStreamRequest& request,
                                 content::MediaResponseCallback callback,
                                 const extensions::Extension* extension) override;
  bool CheckMediaAccessPermission(content::RenderFrameHost* render_frame_host,
                                  const url::Origin& security_origin,
                                  blink::mojom::MediaStreamType type,
                                  const extensions::Extension* extension) override;
  content::PictureInPictureResult EnterPictureInPicture(
      content::WebContents* web_contents) override;
  void ExitPictureInPicture() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_HOST_DELEGATE_H_
