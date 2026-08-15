// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_AUTHENTICATION_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_AUTHENTICATION_DELEGATE_H_

#include <optional>

#include "build/build_config.h"
#include "build/buildflag.h"
#include "content/public/browser/web_authentication_delegate.h"

class PrefRegistrySimple;

namespace orbit {

// content's default returns nullopt from GetTouchIdAuthenticatorConfig, which
// leaves isUVPAA() false and no platform authenticator; this supplies the real
// config so //content instantiates the Touch ID authenticator.
class OrbitWebAuthenticationDelegate : public content::WebAuthenticationDelegate {
 public:
  static void RegisterProfilePrefs(PrefRegistrySimple* registry);

  OrbitWebAuthenticationDelegate();
  OrbitWebAuthenticationDelegate(const OrbitWebAuthenticationDelegate&) = delete;
  OrbitWebAuthenticationDelegate& operator=(
      const OrbitWebAuthenticationDelegate&) = delete;
  ~OrbitWebAuthenticationDelegate() override;

  // content::WebAuthenticationDelegate:
  bool SupportsResidentKeys(
      content::RenderFrameHost* render_frame_host) override;

#if BUILDFLAG(IS_MAC)
  std::optional<TouchIdAuthenticatorConfig> GetTouchIdAuthenticatorConfig(
      content::BrowserContext* browser_context) override;
#endif  // BUILDFLAG(IS_MAC)
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_AUTHENTICATION_DELEGATE_H_
