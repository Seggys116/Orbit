// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Modelled on chrome_extension_system.{h,cc}, but built directly on
// ExtensionRegistrar instead of Chrome-only ExtensionService (which layers
// external-provider/blocklist/delayed-install/sync orchestration Orbit
// doesn't have; see orbit_extension_registrar_delegate.h). extension_service()
// is a real, permanent nullptr: nothing in //extensions itself calls it.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_SYSTEM_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_SYSTEM_H_

#include <memory>
#include <string>

#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/one_shot_event.h"
#include "components/keyed_service/content/browser_context_keyed_service_factory.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/extension_system_provider.h"

namespace value_store {
class ValueStoreFactoryImpl;
}  // namespace value_store

namespace extensions {
class AppSorting;
class ManagementPolicy;
class QuotaService;
class ServiceWorkerManager;
class StateStore;
class UserScriptManager;
}  // namespace extensions

namespace orbit {

class OrbitExtensionRegistrarDelegate;

class OrbitExtensionSystem : public extensions::ExtensionSystem {
 public:
  explicit OrbitExtensionSystem(content::BrowserContext* browser_context);
  OrbitExtensionSystem(const OrbitExtensionSystem&) = delete;
  OrbitExtensionSystem& operator=(const OrbitExtensionSystem&) = delete;
  ~OrbitExtensionSystem() override;

  // KeyedService:
  void Shutdown() override;

  // extensions::ExtensionSystem:
  void InitForRegularProfile(bool extensions_enabled) override;
  extensions::ExtensionService* extension_service() override;
  extensions::ManagementPolicy* management_policy() override;
  extensions::ServiceWorkerManager* service_worker_manager() override;
  extensions::UserScriptManager* user_script_manager() override;
  extensions::StateStore* state_store() override;
  extensions::StateStore* rules_store() override;
  extensions::StateStore* dynamic_user_scripts_store() override;
  scoped_refptr<value_store::ValueStoreFactory> store_factory() override;
  extensions::QuotaService* quota_service() override;
  extensions::AppSorting* app_sorting() override;
  const base::OneShotEvent& ready() const override;
  bool is_ready() const override;
  extensions::ContentVerifier* content_verifier() override;
  void InstallUpdate(const extensions::ExtensionId& extension_id,
                     const std::string& public_key,
                     const base::FilePath& unpacked_dir,
                     bool install_immediately,
                     InstallUpdateCallback install_update_callback) override;
  void PerformActionBasedOnOmahaAttributes(
      const extensions::ExtensionId& extension_id,
      const base::DictValue& attributes) override;

 private:
  raw_ptr<content::BrowserContext> browser_context_;

  scoped_refptr<value_store::ValueStoreFactoryImpl> store_factory_;
  std::unique_ptr<extensions::StateStore> state_store_;
  std::unique_ptr<extensions::StateStore> rules_store_;
  std::unique_ptr<extensions::StateStore> dynamic_user_scripts_store_;
  std::unique_ptr<extensions::ManagementPolicy> management_policy_;
  std::unique_ptr<extensions::ServiceWorkerManager> service_worker_manager_;
  std::unique_ptr<extensions::UserScriptManager> user_script_manager_;
  std::unique_ptr<extensions::QuotaService> quota_service_;
  std::unique_ptr<extensions::AppSorting> app_sorting_;
  std::unique_ptr<OrbitExtensionRegistrarDelegate> registrar_delegate_;

  bool initialized_ = false;
  base::OneShotEvent ready_;
};

// BrowserContextKeyedServiceFactory for OrbitExtensionSystem -- what
// OrbitExtensionsBrowserClient::GetExtensionSystemFactory() returns.
class OrbitExtensionSystemFactory : public extensions::ExtensionSystemProvider {
 public:
  OrbitExtensionSystemFactory(const OrbitExtensionSystemFactory&) = delete;
  OrbitExtensionSystemFactory& operator=(const OrbitExtensionSystemFactory&) = delete;

  extensions::ExtensionSystem* GetForBrowserContext(
      content::BrowserContext* context) override;

  static OrbitExtensionSystemFactory* GetInstance();

 private:
  friend base::NoDestructor<OrbitExtensionSystemFactory>;

  OrbitExtensionSystemFactory();
  ~OrbitExtensionSystemFactory() override;

  // BrowserContextKeyedServiceFactory:
  std::unique_ptr<KeyedService> BuildServiceInstanceForBrowserContext(
      content::BrowserContext* context) const override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_SYSTEM_H_
