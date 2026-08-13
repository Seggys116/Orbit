// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_webstore_private_api_delegate.h"

#include <utility>

#include "base/functional/callback.h"

namespace orbit {

OrbitWebstorePrivateAPIDelegate::OrbitWebstorePrivateAPIDelegate() = default;

OrbitWebstorePrivateAPIDelegate::~OrbitWebstorePrivateAPIDelegate() = default;

// Orbit's webstorePrivate functions answer out of process through Swift, so
// they hold no BrowserContextKeyedService the shutdown notifier must outlive.
std::vector<KeyedServiceBaseFactory*>
OrbitWebstorePrivateAPIDelegate::GetWebStoreAPIFactoryDependencies() {
  return {};
}

// The CRX allowlist is a Safe Browsing feature; Orbit verifies CRX3 signatures
// in its own install pipeline instead.
extensions::ExtensionAllowlist*
OrbitWebstorePrivateAPIDelegate::GetExtensionAllowlist(
    content::BrowserContext* context) {
  return nullptr;
}

// Orbit has no Google sign-in; getStoreLogin is answered by Swift.
signin::IdentityManager* OrbitWebstorePrivateAPIDelegate::GetIdentityManager(
    content::BrowserContext* context) {
  return nullptr;
}

// Install consent and refusal are Swift's, reached through
// native_extension_request; run the callback so no caller is left pending.
void OrbitWebstorePrivateAPIDelegate::ShowExtensionInstallBlockedDialog(
    content::WebContents* web_contents,
    const extensions::Extension* extension,
    const std::u16string& custom_error_message,
    const gfx::ImageSkia& icon,
    base::OnceClosure done_callback) {
  std::move(done_callback).Run();
}

// Friction exists to gate installs Safe Browsing cannot vouch for. Orbit has no
// Safe Browsing, so it cannot be shown, and an unshowable gate must not pass.
void OrbitWebstorePrivateAPIDelegate::ShowExtensionInstallFrictionDialog(
    content::WebContents* web_contents,
    base::OnceCallback<void(bool)> callback) {
  std::move(callback).Run(false);
}

void OrbitWebstorePrivateAPIDelegate::ReportFrictionAcceptedEvent(
    content::BrowserContext* context) {}

#if BUILDFLAG(SAFE_BROWSING_AVAILABLE)
bool OrbitWebstorePrivateAPIDelegate::IsSafeBrowsingEnabledAndReady(
    content::BrowserContext* context) {
  return false;
}

safe_browsing::SafeBrowsingNavigationObserverManager*
OrbitWebstorePrivateAPIDelegate::GetSafeBrowsingNavigationObserverManager(
    content::BrowserContext* context) {
  return nullptr;
}
#endif

// Enterprise promotion banners are Chrome-branded and policy-driven; Orbit
// enrols in neither.
std::unique_ptr<enterprise_promotion::PromotionEligibilityChecker>
OrbitWebstorePrivateAPIDelegate::CreatePromotionEligibilityChecker(
    content::BrowserContext* context,
    bool dismissed_banner_pref,
    bool feature_enabled) {
  return nullptr;
}

}  // namespace orbit
