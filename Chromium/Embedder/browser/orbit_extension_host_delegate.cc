// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_host_delegate.h"

#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_delegate.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_web_contents_host.h"
#include "third_party/blink/public/mojom/mediastream/media_stream.mojom.h"

namespace orbit {

OrbitExtensionHostDelegate::OrbitExtensionHostDelegate() = default;
OrbitExtensionHostDelegate::~OrbitExtensionHostDelegate() = default;

void OrbitExtensionHostDelegate::OnExtensionHostCreated(
    content::WebContents* web_contents) {}

void OrbitExtensionHostDelegate::CreateTab(
    std::unique_ptr<content::WebContents> web_contents,
    const GURL& target_url,
    const extensions::ExtensionId& extension_id,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture) {
  // Every call here is a real "open elsewhere" request (WindowOpenDisposition
  // never means inline), so the adopted WebContents always becomes a genuine
  // Orbit tab, never a settings/options UI. See orbit_tab_registry.h.
  auto* host = new OrbitWebContentsHost(std::move(web_contents));
  if (!RequestExtensionTab(host, target_url.spec(), extension_id,
                          static_cast<int>(disposition), user_gesture)) {
    delete host;
  }
  // On success, Swift now owns this tab and must call OrbitTabsCreated for
  // it before RequestExtensionTab returns.
}

void OrbitExtensionHostDelegate::ProcessMediaAccessRequest(
    content::WebContents* web_contents,
    const content::MediaStreamRequest& request,
    content::MediaResponseCallback callback,
    const extensions::Extension* extension) {
  std::move(callback).Run(blink::mojom::StreamDevicesSet(),
                          blink::mojom::MediaStreamRequestResult::NOT_SUPPORTED,
                          nullptr);
}

bool OrbitExtensionHostDelegate::CheckMediaAccessPermission(
    content::RenderFrameHost* render_frame_host,
    const url::Origin& security_origin,
    blink::mojom::MediaStreamType type,
    const extensions::Extension* extension) {
  return false;
}

content::PictureInPictureResult OrbitExtensionHostDelegate::EnterPictureInPicture(
    content::WebContents* web_contents) {
  return content::PictureInPictureResult::kNotSupported;
}

void OrbitExtensionHostDelegate::ExitPictureInPicture() {}

}  // namespace orbit
