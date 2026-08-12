// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_system.h"

#include "base/command_line.h"
#include "base/no_destructor.h"
#include "components/keyed_service/content/browser_context_dependency_manager.h"
#include "components/value_store/value_store_factory_impl.h"
#include "content/public/browser/browser_context.h"
#include "extensions/browser/event_router_factory.h"
#include "extensions/browser/extension_prefs_factory.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registrar_factory.h"
#include "extensions/browser/extension_registry_factory.h"
#include "extensions/browser/extensions_browser_client.h"
#include "extensions/browser/install/crx_install_error.h"
#include "extensions/browser/load_error_reporter.h"
#include "extensions/browser/management_policy.h"
#include "extensions/browser/null_app_sorting.h"
#include "extensions/browser/process_manager_factory.h"
#include "extensions/browser/quota_service.h"
#include "extensions/browser/renderer_startup_helper.h"
#include "extensions/browser/service_worker_manager.h"
#include "extensions/browser/state_store.h"
#include "extensions/browser/user_script_manager.h"
#include "extensions/common/constants.h"
#include "orbit/browser/orbit_extension_registrar_delegate.h"

namespace orbit {

OrbitExtensionSystem::OrbitExtensionSystem(content::BrowserContext* browser_context)
    : browser_context_(browser_context),
      store_factory_(base::MakeRefCounted<value_store::ValueStoreFactoryImpl>(
          browser_context->GetPath())),
      state_store_(std::make_unique<extensions::StateStore>(
          browser_context_, store_factory_, extensions::StateStore::BackendType::STATE,
          /*deferred_load=*/true)),
      rules_store_(std::make_unique<extensions::StateStore>(
          browser_context_, store_factory_, extensions::StateStore::BackendType::RULES,
          /*deferred_load=*/false)),
      dynamic_user_scripts_store_(std::make_unique<extensions::StateStore>(
          browser_context_, store_factory_, extensions::StateStore::BackendType::SCRIPTS,
          /*deferred_load=*/false)) {}

OrbitExtensionSystem::~OrbitExtensionSystem() = default;

void OrbitExtensionSystem::Shutdown() {}

void OrbitExtensionSystem::InitForRegularProfile(bool extensions_enabled) {
  if (initialized_) {
    return;
  }
  initialized_ = true;

  extensions::LoadErrorReporter::Init(/*enable_noisy_errors=*/true);

  management_policy_ = std::make_unique<extensions::ManagementPolicy>();
  service_worker_manager_ =
      std::make_unique<extensions::ServiceWorkerManager>(browser_context_);
  user_script_manager_ = std::make_unique<extensions::UserScriptManager>(browser_context_);
  quota_service_ = std::make_unique<extensions::QuotaService>();
  app_sorting_ = std::make_unique<extensions::NullAppSorting>();

  registrar_delegate_ = std::make_unique<OrbitExtensionRegistrarDelegate>(browser_context_);
  extensions::ExtensionRegistrar* registrar =
      extensions::ExtensionRegistrar::Get(browser_context_);
  registrar->Init(
      registrar_delegate_.get(), extensions_enabled,
      base::CommandLine::ForCurrentProcess(),
      browser_context_->GetPath().AppendASCII(extensions::kInstallDirectoryName),
      browser_context_->GetPath().AppendASCII(extensions::kUnpackedInstallDirectoryName));
  registrar_delegate_->SetExtensionRegistrar(registrar);

  ready_.Signal();
}

extensions::ExtensionService* OrbitExtensionSystem::extension_service() {
  // See the file comment: Orbit has no Chrome-style ExtensionService.
  return nullptr;
}

extensions::ManagementPolicy* OrbitExtensionSystem::management_policy() {
  return management_policy_.get();
}

extensions::ServiceWorkerManager* OrbitExtensionSystem::service_worker_manager() {
  return service_worker_manager_.get();
}

extensions::UserScriptManager* OrbitExtensionSystem::user_script_manager() {
  return user_script_manager_.get();
}

extensions::StateStore* OrbitExtensionSystem::state_store() {
  return state_store_.get();
}

extensions::StateStore* OrbitExtensionSystem::rules_store() {
  return rules_store_.get();
}

extensions::StateStore* OrbitExtensionSystem::dynamic_user_scripts_store() {
  return dynamic_user_scripts_store_.get();
}

scoped_refptr<value_store::ValueStoreFactory> OrbitExtensionSystem::store_factory() {
  return store_factory_;
}

extensions::QuotaService* OrbitExtensionSystem::quota_service() {
  return quota_service_.get();
}

extensions::AppSorting* OrbitExtensionSystem::app_sorting() {
  return app_sorting_.get();
}

const base::OneShotEvent& OrbitExtensionSystem::ready() const {
  return ready_;
}

bool OrbitExtensionSystem::is_ready() const {
  return ready_.is_signaled();
}

extensions::ContentVerifier* OrbitExtensionSystem::content_verifier() {
  // No content-hash verification of installed extensions yet.
  return nullptr;
}

void OrbitExtensionSystem::InstallUpdate(
    const extensions::ExtensionId& extension_id,
    const std::string& public_key,
    const base::FilePath& unpacked_dir,
    bool install_immediately,
    InstallUpdateCallback install_update_callback) {
  // No CRX auto-update pipeline yet; report failure honestly rather than
  // silently discarding the caller's unpacked_dir.
  std::move(install_update_callback)
      .Run(std::optional<extensions::CrxInstallError>(extensions::CrxInstallError(
          extensions::CrxInstallErrorType::DECLINED,
          extensions::CrxInstallErrorDetail::DISALLOWED_BY_POLICY)));
}

void OrbitExtensionSystem::PerformActionBasedOnOmahaAttributes(
    const extensions::ExtensionId& extension_id,
    const base::DictValue& attributes) {}

OrbitExtensionSystemFactory::OrbitExtensionSystemFactory()
    : extensions::ExtensionSystemProvider(
          "OrbitExtensionSystem", BrowserContextDependencyManager::GetInstance()) {
  DependsOn(extensions::ExtensionPrefsFactory::GetInstance());
  DependsOn(extensions::ExtensionRegistryFactory::GetInstance());
  DependsOn(extensions::ExtensionRegistrarFactory::GetInstance());
  DependsOn(extensions::ProcessManagerFactory::GetInstance());
  DependsOn(extensions::RendererStartupHelperFactory::GetInstance());
  DependsOn(extensions::EventRouterFactory::GetInstance());
}

OrbitExtensionSystemFactory::~OrbitExtensionSystemFactory() = default;

// static
OrbitExtensionSystemFactory* OrbitExtensionSystemFactory::GetInstance() {
  static base::NoDestructor<OrbitExtensionSystemFactory> instance;
  return instance.get();
}

extensions::ExtensionSystem* OrbitExtensionSystemFactory::GetForBrowserContext(
    content::BrowserContext* context) {
  return static_cast<extensions::ExtensionSystem*>(
      GetServiceForBrowserContext(context, true));
}

std::unique_ptr<KeyedService>
OrbitExtensionSystemFactory::BuildServiceInstanceForBrowserContext(
    content::BrowserContext* context) const {
  return std::make_unique<OrbitExtensionSystem>(context);
}

}  // namespace orbit
