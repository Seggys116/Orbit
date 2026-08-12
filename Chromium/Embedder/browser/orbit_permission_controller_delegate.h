// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// content::PermissionControllerDelegate backed by OrbitPermissionStore. Every
// content:: permission surface funnels through content::PermissionController to this.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSION_CONTROLLER_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSION_CONTROLLER_DELEGATE_H_

#include "content/public/browser/permission_controller_delegate.h"
#include "orbit/browser/orbit_permission_store.h"

namespace orbit {

class OrbitPermissionControllerDelegate : public content::PermissionControllerDelegate {
 public:
  explicit OrbitPermissionControllerDelegate(PrefService* pref_service);
  OrbitPermissionControllerDelegate(const OrbitPermissionControllerDelegate&) = delete;
  OrbitPermissionControllerDelegate& operator=(const OrbitPermissionControllerDelegate&) = delete;
  ~OrbitPermissionControllerDelegate() override;

  // content::PermissionControllerDelegate:
  void RequestPermissionsFromCurrentDocument(
      content::RenderFrameHost* render_frame_host,
      const content::PermissionRequestDescription& request_description,
      base::OnceCallback<void(const std::vector<content::PermissionResult>&)> callback)
      override;
  content::PermissionStatus GetPermissionStatus(
      const blink::mojom::PermissionDescriptorPtr& permission,
      const GURL& requesting_origin,
      const GURL& embedding_origin) override;
  content::PermissionResult GetPermissionResultForOriginWithoutContext(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      const url::Origin& requesting_origin,
      const url::Origin& embedding_origin) override;
  content::PermissionResult GetPermissionResultForCurrentDocument(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      content::RenderFrameHost* render_frame_host,
      bool should_include_device_status) override;
  content::PermissionResult GetPermissionResultForWorker(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      content::RenderProcessHost* render_process_host,
      const GURL& worker_origin) override;
  content::PermissionResult GetPermissionResultForEmbeddedRequester(
      const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
      content::RenderFrameHost* render_frame_host,
      const url::Origin& overridden_origin) override;
  void ResetPermission(blink::PermissionType permission,
                       const GURL& requesting_origin,
                       const GURL& embedding_origin) override;

  // The one store this delegate and OrbitGetContentSetting/OrbitSetContentSetting
  // (via OrbitBrowserContext::permission_store()) both read and write -- not a copy.
  OrbitPermissionStore* store() { return &store_; }

 private:
  OrbitPermissionStore store_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSION_CONTROLLER_DELEGATE_H_
