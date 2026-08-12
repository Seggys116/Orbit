// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_management_api_delegate.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/memory/scoped_refptr.h"
#include "extensions/browser/api/management/management_api.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest_handlers/manifest_url_handlers.h"
#include "extensions/common/icons/extension_icon_set.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "orbit/bridge/orbit_bridge_internal.h"

namespace orbit {

namespace {

// Owned by the ManagementUninstallFunctionBase that asked for it; holds a
// reference so a reply arriving after the page went away is still safe.
class OrbitUninstallDialogDelegate : public extensions::UninstallDialogDelegate {
 public:
  explicit OrbitUninstallDialogDelegate(
      extensions::ManagementUninstallFunctionBase* function,
      const std::string& extension_id)
      : function_(function) {
    if (!ManagementRequestUninstallConsent(
            extension_id,
            base::BindOnce(&OrbitUninstallDialogDelegate::OnAnswer,
                           weak_factory_.GetWeakPtr()))) {
      OnAnswer(false);
    }
  }

  ~OrbitUninstallDialogDelegate() override = default;

 private:
  void OnAnswer(bool approved) {
    if (!function_) {
      return;
    }
    scoped_refptr<extensions::ManagementUninstallFunctionBase> function =
        std::move(function_);
    function->OnExtensionUninstallDialogClosed(
        approved, approved ? std::u16string()
                           : u"The user did not approve the uninstall.");
  }

  scoped_refptr<extensions::ManagementUninstallFunctionBase> function_;
  base::WeakPtrFactory<OrbitUninstallDialogDelegate> weak_factory_{this};
};

// Re-enabling an extension whose permissions grew needs a permission prompt
// Orbit does not have, so it is refused rather than granted unprompted.
class OrbitDenyingInstallPromptDelegate
    : public extensions::InstallPromptDelegate {
 public:
  explicit OrbitDenyingInstallPromptDelegate(
      base::OnceCallback<void(bool)> callback) {
    std::move(callback).Run(false);
  }
  ~OrbitDenyingInstallPromptDelegate() override = default;
};

}  // namespace

OrbitManagementAPIDelegate::OrbitManagementAPIDelegate() = default;
OrbitManagementAPIDelegate::~OrbitManagementAPIDelegate() = default;

bool OrbitManagementAPIDelegate::LaunchAppFunctionDelegate(
    const extensions::Extension* extension,
    content::BrowserContext* context) const {
  return false;
}

GURL OrbitManagementAPIDelegate::GetFullLaunchURL(
    const extensions::Extension* extension) const {
  return GURL();
}

extensions::LaunchType OrbitManagementAPIDelegate::GetLaunchType(
    const extensions::ExtensionPrefs* prefs,
    const extensions::Extension* extension) const {
  return extensions::LAUNCH_TYPE_DEFAULT;
}

std::unique_ptr<extensions::InstallPromptDelegate>
OrbitManagementAPIDelegate::SetEnabledFunctionDelegate(
    content::WebContents* web_contents,
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    base::OnceCallback<void(bool)> callback) const {
  return std::make_unique<OrbitDenyingInstallPromptDelegate>(
      std::move(callback));
}

void OrbitManagementAPIDelegate::EnableExtension(
    content::BrowserContext* context,
    const extensions::ExtensionId& extension_id) const {
  ManagementSetExtensionEnabled(extension_id, true);
}

void OrbitManagementAPIDelegate::DisableExtension(
    content::BrowserContext* context,
    const extensions::Extension* source_extension,
    const extensions::ExtensionId& extension_id,
    extensions::disable_reason::DisableReason disable_reason) const {
  ManagementSetExtensionEnabled(extension_id, false);
}

std::unique_ptr<extensions::UninstallDialogDelegate>
OrbitManagementAPIDelegate::UninstallFunctionDelegate(
    extensions::ManagementUninstallFunctionBase* function,
    const extensions::Extension* target_extension,
    bool show_programmatic_uninstall_ui) const {
  return std::make_unique<OrbitUninstallDialogDelegate>(
      function, target_extension ? target_extension->id() : std::string());
}

bool OrbitManagementAPIDelegate::UninstallExtension(
    content::BrowserContext* context,
    const std::string& transient_extension_id,
    extensions::UninstallReason reason,
    std::u16string* error) const {
  // Only ever reached once UninstallFunctionDelegate's prompt was approved.
  if (ManagementUninstallExtension(transient_extension_id)) {
    return true;
  }
  if (error) {
    *error = u"Orbit cannot uninstall this extension right now.";
  }
  return false;
}

bool OrbitManagementAPIDelegate::CreateAppShortcutFunctionDelegate(
    extensions::ManagementCreateAppShortcutFunction* function,
    const extensions::Extension* extension,
    std::string* error) const {
  if (error) {
    *error = "Orbit does not support app shortcuts.";
  }
  return false;
}

void OrbitManagementAPIDelegate::SetLaunchType(
    content::BrowserContext* context,
    const extensions::ExtensionId& extension_id,
    extensions::LaunchType launch_type) const {}

std::unique_ptr<extensions::AppForLinkDelegate>
OrbitManagementAPIDelegate::GenerateAppForLinkFunctionDelegate(
    extensions::ManagementGenerateAppForLinkFunction* function,
    content::BrowserContext* context,
    const std::string& title,
    const GURL& launch_url) const {
  return nullptr;
}

bool OrbitManagementAPIDelegate::CanContextInstallWebApps(
    content::BrowserContext* context) const {
  return false;
}

void OrbitManagementAPIDelegate::InstallOrLaunchReplacementWebApp(
    content::BrowserContext* context,
    const GURL& web_app_url,
    InstallOrLaunchWebAppCallback callback) const {
  std::move(callback).Run(InstallOrLaunchWebAppResult::kInvalidWebApp);
}

GURL OrbitManagementAPIDelegate::GetIconURL(
    const extensions::Extension* extension,
    int icon_size,
    ExtensionIconSet::Match match,
    bool grayscale) const {
  if (!extension) {
    return GURL();
  }
  const std::string& path =
      extensions::IconsInfo::GetIcons(extension).Get(icon_size, match);
  return path.empty() ? GURL() : extension->GetResourceURL(path);
}

GURL OrbitManagementAPIDelegate::GetEffectiveUpdateURL(
    const extensions::Extension& extension,
    content::BrowserContext* context) const {
  return extensions::ManifestURL::GetUpdateURL(&extension);
}

}  // namespace orbit
