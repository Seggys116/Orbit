// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Single-profile content::BrowserContext modelled on shell_browser_context.h;
// unimplemented subsystems return nullptr except downloads/permissions (real).

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_BROWSER_CONTEXT_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_BROWSER_CONTEXT_H_

#include <memory>

#include "base/files/file_path.h"
#include "content/public/browser/browser_context.h"

class PrefService;

namespace custom_handlers {
class ProtocolHandlerRegistry;
}  // namespace custom_handlers

namespace orbit {

class OrbitClientHintsControllerDelegate;
class OrbitDownloadManagerDelegate;
class OrbitPermissionControllerDelegate;
class OrbitPermissionStore;
class OrbitSSLHostStateDelegate;

// ~/Library/Application Support/Orbit unless overridden; forwards to
// orbit/common/orbit_user_data_dir.h, shared with OrbitContentBrowserClient.
base::FilePath OrbitUserDataDir();

class OrbitBrowserContext : public content::BrowserContext {
 public:
  OrbitBrowserContext();
  OrbitBrowserContext(const OrbitBrowserContext&) = delete;
  OrbitBrowserContext& operator=(const OrbitBrowserContext&) = delete;
  ~OrbitBrowserContext() override;

  // Backs extensions::ExtensionPrefs et al. via user_prefs::UserPrefs.
  // JSON-file-backed at GetPath().Append("Preferences").
  PrefService* pref_service() { return pref_service_.get(); }

  // Ensures GetPermissionControllerDelegate() has run and returns its store;
  // called by OrbitGetContentSetting/OrbitSetContentSetting in orbit_bridge_api.cc.
  OrbitPermissionStore* permission_store();

  // Backs ExtensionsBrowserClient::GetProtocolHandlerRegistry; lazily
  // constructed. pref_service_ is already valid by the earliest possible caller.
  custom_handlers::ProtocolHandlerRegistry* protocol_handler_registry();

  // content::BrowserContext:
  std::unique_ptr<content::ZoomLevelDelegate> CreateZoomLevelDelegate(
      const base::FilePath& partition_path) override;
  base::FilePath GetPath() const override;
  bool IsOffTheRecord() override;
  content::DownloadManagerDelegate* GetDownloadManagerDelegate() override;
  content::BrowserPluginGuestManager* GetGuestManager() override;
  storage::SpecialStoragePolicy* GetSpecialStoragePolicy() override;
  content::PlatformNotificationService* GetPlatformNotificationService() override;
  content::PushMessagingService* GetPushMessagingService() override;
  content::StorageNotificationService* GetStorageNotificationService() override;
  content::SSLHostStateDelegate* GetSSLHostStateDelegate() override;
  content::PermissionControllerDelegate* GetPermissionControllerDelegate() override;
  content::ReduceAcceptLanguageControllerDelegate*
  GetReduceAcceptLanguageControllerDelegate() override;
  content::ClientHintsControllerDelegate* GetClientHintsControllerDelegate() override;
  content::BackgroundFetchDelegate* GetBackgroundFetchDelegate() override;
  content::BackgroundSyncController* GetBackgroundSyncController() override;
  content::BrowsingDataRemoverDelegate* GetBrowsingDataRemoverDelegate() override;

 private:
  const base::FilePath path_;
  std::unique_ptr<PrefService> pref_service_;

  // Must stay alive for the rest of ~OrbitBrowserContext(); plain-member
  // ownership (destroyed after the destructor body) guarantees that.
  std::unique_ptr<OrbitDownloadManagerDelegate> download_manager_delegate_;
  std::unique_ptr<OrbitPermissionControllerDelegate> permission_controller_delegate_;
  std::unique_ptr<OrbitSSLHostStateDelegate> ssl_host_state_delegate_;
  std::unique_ptr<OrbitClientHintsControllerDelegate> client_hints_controller_delegate_;
  std::unique_ptr<custom_handlers::ProtocolHandlerRegistry> protocol_handler_registry_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_BROWSER_CONTEXT_H_
