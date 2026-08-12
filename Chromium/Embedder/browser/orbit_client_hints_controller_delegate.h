// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Accept-CH cache and UA Client Hints source; without it content/ sends no
// Sec-CH-UA* headers. Persisted on OrbitPermissionStore's PrefService since
// components/content_settings (where Chrome keeps this) isn't linked here.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_CLIENT_HINTS_CONTROLLER_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_CLIENT_HINTS_CONTROLLER_DELEGATE_H_

#include <vector>

#include "base/memory/raw_ptr.h"
#include "content/public/browser/client_hints_controller_delegate.h"
#include "services/network/public/cpp/network_quality_tracker.h"
#include "ui/gfx/geometry/size.h"

class PrefService;
class PrefRegistrySimple;

namespace orbit {

class OrbitClientHintsControllerDelegate
    : public content::ClientHintsControllerDelegate {
 public:
  static void RegisterProfilePrefs(PrefRegistrySimple* registry);

  // pref_service must outlive this instance -- OrbitBrowserContext owns both.
  explicit OrbitClientHintsControllerDelegate(PrefService* pref_service);
  OrbitClientHintsControllerDelegate(const OrbitClientHintsControllerDelegate&) =
      delete;
  OrbitClientHintsControllerDelegate& operator=(
      const OrbitClientHintsControllerDelegate&) = delete;
  ~OrbitClientHintsControllerDelegate() override;

  // content::ClientHintsControllerDelegate:
  network::NetworkQualityTracker* GetNetworkQualityTracker() override;
  void GetAllowedClientHintsFromSource(
      const url::Origin& origin,
      blink::EnabledClientHints* client_hints) override;
  bool IsJavaScriptAllowed(const GURL& url,
                           content::RenderFrameHost* parent_rfh) override;
  blink::UserAgentMetadata GetUserAgentMetadata() override;
  void PersistClientHints(
      const url::Origin& primary_origin,
      content::RenderFrameHost* parent_rfh,
      const std::vector<network::mojom::WebClientHintsType>& client_hints)
      override;
  void SetAdditionalClientHints(
      const std::vector<network::mojom::WebClientHintsType>& hints) override;
  void ClearAdditionalClientHints() override;
  void SetMostRecentMainFrameViewportSize(
      const gfx::Size& viewport_size) override;
  gfx::Size GetMostRecentMainFrameViewportSize() override;

 private:
  const raw_ptr<PrefService> pref_service_;
  network::NetworkQualityTracker network_quality_tracker_;
  std::vector<network::mojom::WebClientHintsType> additional_hints_;
  gfx::Size viewport_size_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_CLIENT_HINTS_CONTROLLER_DELEGATE_H_
