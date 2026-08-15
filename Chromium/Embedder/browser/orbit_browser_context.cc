// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_browser_context.h"

#include "base/files/file_util.h"
#include "components/custom_handlers/protocol_handler_registry.h"
#include "components/keyed_service/content/browser_context_dependency_manager.h"
#include "components/pref_registry/pref_registry_syncable.h"
#include "components/prefs/json_pref_store.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/pref_service_factory.h"
#include "components/user_prefs/user_prefs.h"
#include "content/public/browser/download_manager.h"
#include "extensions/browser/extension_pref_store.h"
#include "extensions/browser/extension_pref_value_map_factory.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/permissions_manager.h"
#include "orbit/browser/api/preference/orbit_preference_api.h"
#include "orbit/browser/orbit_client_hints_controller_delegate.h"
#include "orbit/browser/orbit_download_manager_delegate.h"
#include "orbit/browser/orbit_permission_controller_delegate.h"
#include "orbit/browser/orbit_permission_store.h"
#include "orbit/browser/orbit_protocol_handler_registry_delegate.h"
#include "orbit/browser/orbit_ssl_host_state_delegate.h"
#include "orbit/browser/orbit_web_authentication_delegate.h"
#include "orbit/common/orbit_user_data_dir.h"

namespace orbit {

namespace {

std::unique_ptr<PrefService> BuildPrefService(const base::FilePath& profile_path,
                                              content::BrowserContext* context) {
  auto registry = base::MakeRefCounted<user_prefs::PrefRegistrySyncable>();
  extensions::PermissionsManager::RegisterProfilePrefs(registry.get());
  extensions::ExtensionPrefs::RegisterProfilePrefs(registry.get());
  OrbitPermissionStore::RegisterProfilePrefs(registry.get());
  OrbitClientHintsControllerDelegate::RegisterProfilePrefs(registry.get());
  OrbitWebAuthenticationDelegate::RegisterProfilePrefs(registry.get());
  custom_handlers::ProtocolHandlerRegistry::RegisterProfilePrefs(registry.get());
  // chrome.privacy.services.searchSuggestEnabled, and the Profile toggle in
  // Settings, are the same pref -- see orbit_preference_event_router.h.
  registry->RegisterBooleanPref(kSearchSuggestEnabledPref, true);

  PrefServiceFactory factory;
  factory.set_user_prefs(
      base::MakeRefCounted<JsonPrefStore>(profile_path.Append("Preferences")));
  // Extension-set values take precedence over the user value (backs
  // ChromeSetting.levelOfControl); mirrors Profile::CreateExtensionPrefStore.
  if (ExtensionPrefValueMap* pref_value_map =
          ExtensionPrefValueMapFactory::GetForBrowserContext(context)) {
    factory.set_extension_prefs(base::MakeRefCounted<ExtensionPrefStore>(
        pref_value_map, /*incognito_pref_store=*/false));
  }
  // Synchronous: extensions:: consumers (ExtensionPrefs, PermissionsManager)
  // are constructed synchronously at startup and would read defaults instead.
  factory.set_async(false);
  return factory.Create(registry);
}

}  // namespace

base::FilePath OrbitUserDataDir() {
  return ResolveOrbitUserDataDir();
}

OrbitBrowserContext::OrbitBrowserContext() : path_(OrbitUserDataDir()) {
  base::CreateDirectory(path_);
  pref_service_ = BuildPrefService(path_, this);
  user_prefs::UserPrefs::Set(this, pref_service_.get());

  // Eagerly builds every kServiceIsCreatedWithBrowserContext API (e.g.
  // ManagementAPI) so it observes EventRouter before a page can addListener().
  BrowserContextDependencyManager::GetInstance()
      ->CreateBrowserContextServices(this);
}

OrbitBrowserContext::~OrbitBrowserContext() {
  NotifyWillBeDestroyed();
  ShutdownStoragePartitions();
  BrowserContextDependencyManager::GetInstance()
      ->DestroyBrowserContextServices(this);
  // Consumers of GetProtocolHandlerRegistry() are torn down above; finalize
  // the registry itself now, as BrowserContextKeyedServiceFactory would.
  if (protocol_handler_registry_) {
    protocol_handler_registry_->Shutdown();
  }
}

std::unique_ptr<content::ZoomLevelDelegate>
OrbitBrowserContext::CreateZoomLevelDelegate(const base::FilePath&) {
  return nullptr;
}

base::FilePath OrbitBrowserContext::GetPath() const {
  return path_;
}

bool OrbitBrowserContext::IsOffTheRecord() {
  return false;
}

OrbitPermissionStore* OrbitBrowserContext::permission_store() {
  GetPermissionControllerDelegate();
  return permission_controller_delegate_->store();
}

custom_handlers::ProtocolHandlerRegistry*
OrbitBrowserContext::protocol_handler_registry() {
  if (!protocol_handler_registry_) {
    protocol_handler_registry_ = custom_handlers::ProtocolHandlerRegistry::Create(
        pref_service_.get(),
        std::make_unique<OrbitProtocolHandlerRegistryDelegate>(),
        /*is_off_the_record=*/false);
  }
  return protocol_handler_registry_.get();
}

content::DownloadManagerDelegate*
OrbitBrowserContext::GetDownloadManagerDelegate() {
  if (!download_manager_delegate_) {
    download_manager_delegate_ = std::make_unique<OrbitDownloadManagerDelegate>();
    // Safe reentrancy: BrowserContextImpl::GetDownloadManager() assigns its
    // download_manager_ before calling GetDownloadManagerDelegate(), so this
    // inner call returns the already-constructed manager, not recursion.
    download_manager_delegate_->SetDownloadManager(GetDownloadManager());
  }
  return download_manager_delegate_.get();
}

content::BrowserPluginGuestManager* OrbitBrowserContext::GetGuestManager() {
  return nullptr;
}

storage::SpecialStoragePolicy* OrbitBrowserContext::GetSpecialStoragePolicy() {
  return nullptr;
}

content::PlatformNotificationService*
OrbitBrowserContext::GetPlatformNotificationService() {
  return nullptr;
}

content::PushMessagingService* OrbitBrowserContext::GetPushMessagingService() {
  return nullptr;
}

content::StorageNotificationService*
OrbitBrowserContext::GetStorageNotificationService() {
  return nullptr;
}

// Without one, SSLManager::OnCertError denies every cert error unconditionally,
// so a page already clicked through on Orbit's interstitial could never load.
content::SSLHostStateDelegate* OrbitBrowserContext::GetSSLHostStateDelegate() {
  if (!ssl_host_state_delegate_) {
    ssl_host_state_delegate_ = std::make_unique<OrbitSSLHostStateDelegate>();
  }
  return ssl_host_state_delegate_.get();
}

content::PermissionControllerDelegate*
OrbitBrowserContext::GetPermissionControllerDelegate() {
  if (!permission_controller_delegate_) {
    permission_controller_delegate_ =
        std::make_unique<OrbitPermissionControllerDelegate>(pref_service_.get());
  }
  return permission_controller_delegate_.get();
}

content::ReduceAcceptLanguageControllerDelegate*
OrbitBrowserContext::GetReduceAcceptLanguageControllerDelegate() {
  return nullptr;
}

content::ClientHintsControllerDelegate*
OrbitBrowserContext::GetClientHintsControllerDelegate() {
  // Lazy: the delegate opens a mojo channel to the network service in its
  // constructor, and the first caller here is a navigation, once it exists.
  if (!client_hints_controller_delegate_) {
    client_hints_controller_delegate_ =
        std::make_unique<OrbitClientHintsControllerDelegate>(pref_service_.get());
  }
  return client_hints_controller_delegate_.get();
}

content::BackgroundFetchDelegate*
OrbitBrowserContext::GetBackgroundFetchDelegate() {
  return nullptr;
}

content::BackgroundSyncController*
OrbitBrowserContext::GetBackgroundSyncController() {
  return nullptr;
}

content::BrowsingDataRemoverDelegate*
OrbitBrowserContext::GetBrowsingDataRemoverDelegate() {
  return nullptr;
}

}  // namespace orbit
