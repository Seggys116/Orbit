// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_MANAGEMENT_API_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_MANAGEMENT_API_DELEGATE_H_

#include <memory>
#include <string>

#include "extensions/browser/api/management/management_api_delegate.h"

namespace orbit {

// chrome.management is scoped to the Web Store origin; a null delegate crashes
// on first call. Enable/disable/uninstall route through OrbitSetManagementDelegate.
class OrbitManagementAPIDelegate : public extensions::ManagementAPIDelegate {
 public:
  OrbitManagementAPIDelegate();
  OrbitManagementAPIDelegate(const OrbitManagementAPIDelegate&) = delete;
  OrbitManagementAPIDelegate& operator=(const OrbitManagementAPIDelegate&) =
      delete;
  ~OrbitManagementAPIDelegate() override;

  // extensions::ManagementAPIDelegate:
  bool LaunchAppFunctionDelegate(
      const extensions::Extension* extension,
      content::BrowserContext* context) const override;
  GURL GetFullLaunchURL(const extensions::Extension* extension) const override;
  extensions::LaunchType GetLaunchType(
      const extensions::ExtensionPrefs* prefs,
      const extensions::Extension* extension) const override;
  std::unique_ptr<extensions::InstallPromptDelegate> SetEnabledFunctionDelegate(
      content::WebContents* web_contents,
      content::BrowserContext* browser_context,
      const extensions::Extension* extension,
      base::OnceCallback<void(bool)> callback) const override;
  void EnableExtension(content::BrowserContext* context,
                       const extensions::ExtensionId& extension_id) const override;
  void DisableExtension(
      content::BrowserContext* context,
      const extensions::Extension* source_extension,
      const extensions::ExtensionId& extension_id,
      extensions::disable_reason::DisableReason disable_reason) const override;
  std::unique_ptr<extensions::UninstallDialogDelegate> UninstallFunctionDelegate(
      extensions::ManagementUninstallFunctionBase* function,
      const extensions::Extension* target_extension,
      bool show_programmatic_uninstall_ui) const override;
  bool UninstallExtension(content::BrowserContext* context,
                          const std::string& transient_extension_id,
                          extensions::UninstallReason reason,
                          std::u16string* error) const override;
  bool CreateAppShortcutFunctionDelegate(
      extensions::ManagementCreateAppShortcutFunction* function,
      const extensions::Extension* extension,
      std::string* error) const override;
  void SetLaunchType(content::BrowserContext* context,
                     const extensions::ExtensionId& extension_id,
                     extensions::LaunchType launch_type) const override;
  std::unique_ptr<extensions::AppForLinkDelegate>
  GenerateAppForLinkFunctionDelegate(
      extensions::ManagementGenerateAppForLinkFunction* function,
      content::BrowserContext* context,
      const std::string& title,
      const GURL& launch_url) const override;
  bool CanContextInstallWebApps(content::BrowserContext* context) const override;
  void InstallOrLaunchReplacementWebApp(
      content::BrowserContext* context,
      const GURL& web_app_url,
      InstallOrLaunchWebAppCallback callback) const override;
  GURL GetIconURL(const extensions::Extension* extension,
                  int icon_size,
                  ExtensionIconSet::Match match,
                  bool grayscale) const override;
  GURL GetEffectiveUpdateURL(const extensions::Extension& extension,
                             content::BrowserContext* context) const override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_MANAGEMENT_API_DELEGATE_H_
