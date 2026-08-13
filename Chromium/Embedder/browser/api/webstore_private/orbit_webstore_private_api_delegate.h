// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// 152 moved webstore_private from //chrome into //extensions, so the core
// factory registration now runs in Orbit and dereferences this delegate.
// Orbit serves chrome.webstorePrivate from orbit::WebstorePrivate*Function
// against Swift's verified install pipeline, never upstream's WebstoreInstaller.

#ifndef ORBIT_EMBEDDER_BROWSER_API_WEBSTORE_PRIVATE_ORBIT_WEBSTORE_PRIVATE_API_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_API_WEBSTORE_PRIVATE_ORBIT_WEBSTORE_PRIVATE_API_DELEGATE_H_

#include <memory>
#include <string>
#include <vector>

#include "extensions/browser/api/webstore_private/webstore_private_api_delegate.h"

namespace orbit {

class OrbitWebstorePrivateAPIDelegate
    : public extensions::WebstorePrivateAPIDelegate {
 public:
  OrbitWebstorePrivateAPIDelegate();
  OrbitWebstorePrivateAPIDelegate(const OrbitWebstorePrivateAPIDelegate&) =
      delete;
  OrbitWebstorePrivateAPIDelegate& operator=(
      const OrbitWebstorePrivateAPIDelegate&) = delete;
  ~OrbitWebstorePrivateAPIDelegate() override;

  // extensions::WebstorePrivateAPIDelegate:
  std::vector<KeyedServiceBaseFactory*> GetWebStoreAPIFactoryDependencies()
      override;
  extensions::ExtensionAllowlist* GetExtensionAllowlist(
      content::BrowserContext* context) override;
  signin::IdentityManager* GetIdentityManager(
      content::BrowserContext* context) override;
  void ShowExtensionInstallBlockedDialog(
      content::WebContents* web_contents,
      const extensions::Extension* extension,
      const std::u16string& custom_error_message,
      const gfx::ImageSkia& icon,
      base::OnceClosure done_callback) override;
  void ShowExtensionInstallFrictionDialog(
      content::WebContents* web_contents,
      base::OnceCallback<void(bool)> callback) override;
  void ReportFrictionAcceptedEvent(content::BrowserContext* context) override;
#if BUILDFLAG(SAFE_BROWSING_AVAILABLE)
  bool IsSafeBrowsingEnabledAndReady(content::BrowserContext* context) override;
  safe_browsing::SafeBrowsingNavigationObserverManager*
  GetSafeBrowsingNavigationObserverManager(
      content::BrowserContext* context) override;
#endif
  std::unique_ptr<enterprise_promotion::PromotionEligibilityChecker>
  CreatePromotionEligibilityChecker(content::BrowserContext* context,
                                    bool dismissed_banner_pref,
                                    bool feature_enabled) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_WEBSTORE_PRIVATE_ORBIT_WEBSTORE_PRIVATE_API_DELEGATE_H_
