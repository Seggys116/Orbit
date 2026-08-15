// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_browser_main_parts.h"

#include "base/run_loop.h"
#include "extensions/browser/api/extensions_api_client.h"
#include "orbit/browser/orbit_extensions_api_client.h"
#include "extensions/browser/browser_context_keyed_service_factories.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/extensions_browser_client.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_bookmark_registry.h"
#include "orbit/browser/orbit_browser_context.h"
#include "orbit/browser/orbit_command_service.h"
#include "orbit/browser/orbit_cookies_event_router.h"
#include "orbit/browser/orbit_download_registry.h"
#include "orbit/browser/orbit_devtools_web_ui.h"
#include "orbit/browser/orbit_extension_action_dispatcher.h"
#include "orbit/browser/orbit_extensions_browser_client.h"
#include "orbit/browser/orbit_menu_manager.h"
#include "orbit/browser/orbit_permissions_event_router.h"
#include "orbit/browser/orbit_preference_event_router.h"
#include "ui/display/screen.h"

namespace orbit {

OrbitBrowserMainParts::OrbitBrowserMainParts() = default;

OrbitBrowserMainParts::~OrbitBrowserMainParts() {
  ClearOrbitBrowserState();
}

int OrbitBrowserMainParts::PreEarlyInitialization() {
  screen_ = std::make_unique<display::ScopedNativeScreen>();
  return 0;
}

int OrbitBrowserMainParts::PreMainMessageLoopRun() {
  native_nested_loop_guard_ = std::make_unique<OrbitNativeNestedLoopGuard>();
  RegisterOrbitDevToolsWebUI();

  // Strict order: factories read ExtensionsBrowserClient::Get() as built and
  // must exist before any BrowserContext for DependencyManager to order them.
  extensions_browser_client_ = std::make_unique<OrbitExtensionsBrowserClient>();
  extensions::ExtensionsBrowserClient::Set(extensions_browser_client_.get());
  extensions_api_client_ = std::make_unique<OrbitExtensionsAPIClient>();
  extensions::EnsureBrowserContextKeyedServiceFactoriesBuilt();

  browser_context_ = std::make_unique<OrbitBrowserContext>();
  extensions_browser_client_->SetBrowserContext(browser_context_.get());
  extensions::ExtensionSystem::Get(browser_context_.get())
      ->InitForRegularProfile(/*extensions_enabled=*/true);

  OrbitExtensionActionDispatcher::GetInstance().StartObserving(
      browser_context_.get());
  OrbitBookmarkRegistry::GetInstance().StartObserving(browser_context_.get());
  OrbitCommandService::GetInstance().StartObserving(browser_context_.get());
  OrbitCookiesEventRouter::GetInstance().StartObserving(browser_context_.get());
  OrbitDownloadRegistry::GetInstance().StartObserving(browser_context_.get());
  OrbitMenuManager::GetInstance().StartObserving(browser_context_.get());
  OrbitPermissionsEventRouter::GetInstance().StartObserving(browser_context_.get());
  OrbitPreferenceEventRouter::GetInstance().StartObserving(browser_context_.get());

  NotifyOrbitBrowserReady(browser_context_.get());
  return 0;
}

void OrbitBrowserMainParts::WillRunMainMessageLoop(
    std::unique_ptr<base::RunLoop>& run_loop) {
  SetOrbitBrowserQuitClosure(run_loop->QuitClosure());
}

void OrbitBrowserMainParts::PostMainMessageLoopRun() {
  ClearOrbitBrowserState();
  OrbitExtensionActionDispatcher::GetInstance().StopObserving();
  OrbitExtensionActionDispatcher::GetInstance().SetCallback(nullptr, nullptr);
  OrbitBookmarkRegistry::GetInstance().StopObserving();
  OrbitBookmarkRegistry::GetInstance().SetRequestCallback(nullptr, nullptr);
  OrbitDownloadRegistry::GetInstance().StopObserving();
  OrbitDownloadRegistry::GetInstance().SetRequestCallback(nullptr, nullptr);
  OrbitCommandService::GetInstance().StopObserving();
  OrbitCommandService::GetInstance().SetCommandsCallback(nullptr, nullptr);
  OrbitCommandService::GetInstance().SetActionActivatedCallback(nullptr, nullptr);
  OrbitCookiesEventRouter::GetInstance().StopObserving();
  OrbitMenuManager::GetInstance().StopObserving();
  OrbitPermissionsEventRouter::GetInstance().StopObserving();
  OrbitPreferenceEventRouter::GetInstance().StopObserving();
  OrbitPreferenceEventRouter::GetInstance().SetSearchSuggestCallback(nullptr, nullptr);
  browser_context_.reset();
  if (extensions::ExtensionsBrowserClient::Get() == extensions_browser_client_.get()) {
    extensions::ExtensionsBrowserClient::Set(nullptr);
  }
  extensions_api_client_.reset();
  extensions_browser_client_.reset();
  native_nested_loop_guard_.reset();
}

}  // namespace orbit
