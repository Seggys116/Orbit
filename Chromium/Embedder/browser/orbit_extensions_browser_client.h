// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Browser-process counterpart to OrbitExtensionsClient. Single always-non-incognito
// BrowserContext: every OTR/original redirection method returns context unchanged.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_BROWSER_CLIENT_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_BROWSER_CLIENT_H_

#include <memory>
#include <string>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "extensions/browser/extensions_browser_client.h"

namespace custom_handlers {
class ProtocolHandlerRegistry;
}  // namespace custom_handlers

namespace extensions {
class KioskDelegate;
class SafeBrowsingDelegate;
class ScriptExecutor;
}  // namespace extensions

namespace orbit {

class OrbitExtensionManagementClient;

class OrbitExtensionsBrowserClient : public extensions::ExtensionsBrowserClient {
 public:
  OrbitExtensionsBrowserClient();
  OrbitExtensionsBrowserClient(const OrbitExtensionsBrowserClient&) = delete;
  OrbitExtensionsBrowserClient& operator=(const OrbitExtensionsBrowserClient&) = delete;
  ~OrbitExtensionsBrowserClient() override;

  // Set once the BrowserContext exists. The client must be registered before
  // that, because the keyed-service factories consult it as they are built.
  void SetBrowserContext(content::BrowserContext* browser_context);

  // extensions::ExtensionsBrowserClient:
  void Init() override;
  bool IsShuttingDown() override;
  bool AreExtensionsDisabled(const base::CommandLine& command_line,
                             content::BrowserContext* context) override;
  bool IsValidContext(void* context) override;
  bool IsSameContext(content::BrowserContext* first,
                     content::BrowserContext* second) override;
  bool HasOffTheRecordContext(content::BrowserContext* context) override;
  content::BrowserContext* GetOffTheRecordContext(
      content::BrowserContext* context) override;
  content::BrowserContext* GetOriginalContext(
      content::BrowserContext* context) override;
  content::BrowserContext* GetContextRedirectedToOriginal(
      content::BrowserContext* context) override;
  content::BrowserContext* GetContextRedirectedToOriginalWithoutAshInternals(
      content::BrowserContext* context) override;
  content::BrowserContext* GetContextOwnInstance(
      content::BrowserContext* context) override;
  content::BrowserContext* GetContextForOriginalOnly(
      content::BrowserContext* context) override;
  bool AreExtensionsDisabledForContext(content::BrowserContext* context) override;
  bool IsGuestSession(content::BrowserContext* context) const override;
  bool IsExtensionIncognitoEnabled(const extensions::ExtensionId& extension_id,
                                   content::BrowserContext* context) const override;
  bool IsExtensionIncognitoEnabled(const extensions::Extension* extension,
                                   content::BrowserContext* context) const override;
  bool CanExtensionCrossIncognito(const extensions::Extension* extension,
                                  content::BrowserContext* context) const override;
  base::FilePath GetBundleResourcePath(
      const network::ResourceRequest& request,
      const base::FilePath& extension_resources_path,
      int* resource_id) const override;
  void LoadResourceFromResourceBundle(
      const network::ResourceRequest& request,
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      const base::FilePath& resource_relative_path,
      int resource_id,
      scoped_refptr<net::HttpResponseHeaders> headers,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      content::BrowserContext* browser_context) override;
  bool AllowCrossRendererResourceLoad(
      const network::ResourceRequest& request,
      network::mojom::RequestDestination destination,
      ui::PageTransition page_transition,
      content::ChildProcessId child_id,
      bool is_incognito,
      const extensions::Extension* extension,
      const extensions::ExtensionSet& extensions,
      const extensions::ProcessMap& process_map,
      const GURL& upstream_url) override;
  void GetTabAndWindowIdForWebContents(content::WebContents* web_contents,
                                       int* tab_id,
                                       int* window_id) override;
  bool IsValidTabId(content::BrowserContext* browser_context,
                    int tab_id,
                    bool include_incognito,
                    content::WebContents** web_contents) const override;
  extensions::ScriptExecutor* GetScriptExecutorForTab(
      content::WebContents& web_contents) override;
  void GetEarlyExtensionPrefsObservers(
      content::BrowserContext* context,
      std::vector<extensions::EarlyExtensionPrefsObserver*>* observers) const override;
  extensions::ProcessManagerDelegate* GetProcessManagerDelegate() const override;
  mojo::PendingRemote<network::mojom::URLLoaderFactory>
  GetControlledFrameEmbedderURLLoader(
      const url::Origin& app_origin,
      content::FrameTreeNodeId frame_tree_node_id,
      content::BrowserContext* browser_context) override;
  std::unique_ptr<extensions::ExtensionHostDelegate> CreateExtensionHostDelegate() override;
  bool DidVersionUpdate(content::BrowserContext* context) override;
  void PermitExternalProtocolHandler() override;
  bool IsInDemoMode() override;
  bool IsScreensaverInDemoMode(const std::string& app_id) override;
  bool IsRunningInForcedAppMode() override;
  bool IsAppModeForcedForApp(const extensions::ExtensionId& extension_id) override;
  bool IsLoggedInAsPublicAccount() override;
  extensions::ExtensionSystemProvider* GetExtensionSystemFactory() override;
  void RegisterBrowserInterfaceBindersForFrame(
      mojo::BinderMapWithContext<content::RenderFrameHost*>* binder_map,
      content::RenderFrameHost* render_frame_host,
      const extensions::Extension* extension) const override;
  std::unique_ptr<extensions::RuntimeAPIDelegate> CreateRuntimeAPIDelegate(
      content::BrowserContext* context) const override;
  const extensions::ComponentExtensionResourceManager*
  GetComponentExtensionResourceManager() override;
  void BroadcastEventToRenderers(extensions::events::HistogramValue histogram_value,
                                 const std::string& event_name,
                                 base::ListValue args,
                                 bool dispatch_to_off_the_record_profiles) override;
  extensions::ExtensionCache* GetExtensionCache() override;
  bool IsBackgroundUpdateAllowed() override;
  bool IsMinBrowserVersionSupported(const std::string& min_version) override;
  void CreateExtensionWebContentsObserver(content::WebContents* web_contents) override;
  extensions::ExtensionWebContentsObserver* GetExtensionWebContentsObserver(
      content::WebContents* web_contents) override;
  extensions::KioskDelegate* GetKioskDelegate() override;
  extensions::SafeBrowsingDelegate* GetSafeBrowsingDelegate() override;
  std::string GetApplicationLocale() override;
  extensions::ExtensionManagementClient* GetExtensionManagementClient(
      content::BrowserContext* context) override;
  bool IsExtensionEnabled(const extensions::ExtensionId& extension_id,
                          content::BrowserContext* context) const override;
  custom_handlers::ProtocolHandlerRegistry* GetProtocolHandlerRegistry(
      content::BrowserContext* context) override;

 private:
  raw_ptr<content::BrowserContext> browser_context_ = nullptr;
  std::unique_ptr<OrbitExtensionManagementClient> extension_management_client_;
  std::unique_ptr<extensions::SafeBrowsingDelegate> safe_browsing_delegate_;
  std::unique_ptr<extensions::KioskDelegate> kiosk_delegate_;
  std::unique_ptr<extensions::ExtensionCache> extension_cache_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_BROWSER_CLIENT_H_
