// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extensions_browser_client.h"

#include "base/command_line.h"
#include "base/version.h"
#include "base/version_info/version_info.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/url_constants.h"
#include "extensions/browser/api/core_extensions_browser_api_provider.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/kiosk/kiosk_delegate.h"
#include "extensions/browser/safe_browsing_delegate.h"
#include "extensions/browser/script_executor.h"
#include "extensions/browser/updater/null_extension_cache.h"
#include "extensions/browser/url_request_util.h"
#include "extensions/common/manifest_handlers/devtools_page_handler.h"
#include "extensions/common/switches.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "services/network/public/cpp/resource_request.h"
#include "net/http/http_response_headers.h"
#include "orbit/browser/orbit_browser_context.h"
#include "orbit/browser/orbit_extension_host_delegate.h"
#include "orbit/browser/orbit_extension_management_client.h"
#include "orbit/browser/orbit_extension_system.h"
#include "orbit/browser/orbit_extension_web_contents_observer.h"
#include "orbit/browser/orbit_extensions_browser_api_provider.h"
#include "orbit/browser/orbit_webstore_private_browser_api_provider.h"
#include "orbit/browser/orbit_runtime_api_delegate.h"
#include "ui/base/l10n/l10n_util.h"

namespace orbit {

namespace {

// Orbit has no kiosk mode on any platform it ships.
class OrbitKioskDelegate : public extensions::KioskDelegate {
 public:
  bool IsAutoLaunchedKioskApp(const extensions::ExtensionId& id) const override {
    return false;
  }
};

}  // namespace

OrbitExtensionsBrowserClient::OrbitExtensionsBrowserClient()
    : extension_management_client_(std::make_unique<OrbitExtensionManagementClient>()),
      safe_browsing_delegate_(std::make_unique<extensions::SafeBrowsingDelegate>()),
      kiosk_delegate_(std::make_unique<OrbitKioskDelegate>()),
      extension_cache_(std::make_unique<extensions::NullExtensionCache>()) {
  AddAPIProvider(std::make_unique<extensions::CoreExtensionsBrowserAPIProvider>());
  // chrome.tabs/chrome.windows ExtensionFunctions -- see
  // orbit_extensions_browser_api_provider.h.
  AddAPIProvider(std::make_unique<OrbitExtensionsBrowserAPIProvider>());
  AddAPIProvider(std::make_unique<OrbitWebstorePrivateBrowserAPIProvider>());
}

OrbitExtensionsBrowserClient::~OrbitExtensionsBrowserClient() = default;

void OrbitExtensionsBrowserClient::SetBrowserContext(
    content::BrowserContext* browser_context) {
  browser_context_ = browser_context;
}

void OrbitExtensionsBrowserClient::Init() {}

bool OrbitExtensionsBrowserClient::IsShuttingDown() {
  return false;
}

bool OrbitExtensionsBrowserClient::AreExtensionsDisabled(
    const base::CommandLine& command_line,
    content::BrowserContext* context) {
  return command_line.HasSwitch(extensions::switches::kDisableExtensions);
}

bool OrbitExtensionsBrowserClient::IsValidContext(void* context) {
  return context == browser_context_;
}

bool OrbitExtensionsBrowserClient::IsSameContext(content::BrowserContext* first,
                                                 content::BrowserContext* second) {
  return first == second;
}

bool OrbitExtensionsBrowserClient::HasOffTheRecordContext(
    content::BrowserContext* context) {
  // Orbit has no incognito/off-the-record profile yet.
  return false;
}

content::BrowserContext* OrbitExtensionsBrowserClient::GetOffTheRecordContext(
    content::BrowserContext* context) {
  return nullptr;
}

content::BrowserContext* OrbitExtensionsBrowserClient::GetOriginalContext(
    content::BrowserContext* context) {
  return context;
}

content::BrowserContext*
OrbitExtensionsBrowserClient::GetContextRedirectedToOriginal(
    content::BrowserContext* context) {
  return context;
}

content::BrowserContext*
OrbitExtensionsBrowserClient::GetContextRedirectedToOriginalWithoutAshInternals(
    content::BrowserContext* context) {
  return context;
}

content::BrowserContext* OrbitExtensionsBrowserClient::GetContextOwnInstance(
    content::BrowserContext* context) {
  return context;
}

content::BrowserContext* OrbitExtensionsBrowserClient::GetContextForOriginalOnly(
    content::BrowserContext* context) {
  return context;
}

bool OrbitExtensionsBrowserClient::AreExtensionsDisabledForContext(
    content::BrowserContext* context) {
  return false;
}

bool OrbitExtensionsBrowserClient::IsGuestSession(
    content::BrowserContext* context) const {
  return false;
}

bool OrbitExtensionsBrowserClient::IsExtensionIncognitoEnabled(
    const extensions::ExtensionId& extension_id,
    content::BrowserContext* context) const {
  return false;
}

bool OrbitExtensionsBrowserClient::IsExtensionIncognitoEnabled(
    const extensions::Extension* extension,
    content::BrowserContext* context) const {
  return false;
}

bool OrbitExtensionsBrowserClient::CanExtensionCrossIncognito(
    const extensions::Extension* extension,
    content::BrowserContext* context) const {
  return false;
}

base::FilePath OrbitExtensionsBrowserClient::GetBundleResourcePath(
    const network::ResourceRequest& request,
    const base::FilePath& extension_resources_path,
    int* resource_id) const {
  // Orbit ships no component extensions, so nothing resolves to a .pak entry.
  *resource_id = 0;
  return base::FilePath();
}

void OrbitExtensionsBrowserClient::LoadResourceFromResourceBundle(
    const network::ResourceRequest& request,
    mojo::PendingReceiver<network::mojom::URLLoader> loader,
    const base::FilePath& resource_relative_path,
    int resource_id,
    scoped_refptr<net::HttpResponseHeaders> headers,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client) {
  NOTREACHED() << "GetBundleResourcePath() never returns a non-empty path";
}

bool OrbitExtensionsBrowserClient::AllowCrossRendererResourceLoad(
    const network::ResourceRequest& request,
    network::mojom::RequestDestination destination,
    ui::PageTransition page_transition,
    content::ChildProcessId child_id,
    bool is_incognito,
    const extensions::Extension* extension,
    const extensions::ExtensionSet& extensions,
    const extensions::ProcessMap& process_map,
    const GURL& upstream_url) {
  // `extensions` (the parameter) shadows the namespace, so every symbol from
  // it has to be named with a leading `::`.
  bool allowed = false;
  if (::extensions::url_request_util::AllowCrossRendererResourceLoad(
          request, destination, page_transition, child_id, is_incognito,
          extension, extensions, process_map, upstream_url, &allowed)) {
    return allowed;
  }

  if (extension && !::extensions::chrome_manifest_urls::GetDevToolsPage(extension)
                        .is_empty()) {
    // No initiator means a browser-initiated request.
    if (!request.request_initiator ||
        request.request_initiator->scheme() == content::kChromeDevToolsScheme) {
      return true;
    }
  }

  // Undetermined: block.
  return false;
}

void OrbitExtensionsBrowserClient::GetTabAndWindowIdForWebContents(
    content::WebContents* web_contents,
    int* tab_id,
    int* window_id) {
  // Without this, every webRequest event for a navigation reports tabId -1,
  // and real extensions key their per-tab state on it.
  const OrbitTabInfo* tab =
      OrbitTabRegistry::GetInstance().GetTabForWebContents(web_contents);
  if (tab) {
    *tab_id = tab->id;
    *window_id = tab->window_id;
    return;
  }
  *tab_id = -1;
  *window_id = -1;
}

bool OrbitExtensionsBrowserClient::IsValidTabId(
    content::BrowserContext* browser_context,
    int tab_id,
    bool include_incognito,
    content::WebContents** web_contents) const {
  // Without this and GetScriptExecutorForTab, chrome.scripting.* calls fail
  // with "No tab with id". `include_incognito` is ignored: single BrowserContext.
  const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(tab_id);
  if (!tab || !tab->web_contents) {
    return false;
  }
  if (tab->web_contents->GetBrowserContext() != browser_context) {
    return false;
  }
  if (web_contents) {
    *web_contents = tab->web_contents.get();
  }
  return true;
}

extensions::ScriptExecutor*
OrbitExtensionsBrowserClient::GetScriptExecutorForTab(
    content::WebContents& web_contents) {
  OrbitExtensionWebContentsObserver* observer =
      OrbitExtensionWebContentsObserver::FromWebContents(&web_contents);
  return observer ? observer->script_executor() : nullptr;
}

void OrbitExtensionsBrowserClient::GetEarlyExtensionPrefsObservers(
    content::BrowserContext* context,
    std::vector<extensions::EarlyExtensionPrefsObserver*>* observers) const {}

extensions::ProcessManagerDelegate*
OrbitExtensionsBrowserClient::GetProcessManagerDelegate() const {
  return nullptr;
}

mojo::PendingRemote<network::mojom::URLLoaderFactory>
OrbitExtensionsBrowserClient::GetControlledFrameEmbedderURLLoader(
    const url::Origin& app_origin,
    content::FrameTreeNodeId frame_tree_node_id,
    content::BrowserContext* browser_context) {
  return mojo::PendingRemote<network::mojom::URLLoaderFactory>();
}

std::unique_ptr<extensions::ExtensionHostDelegate>
OrbitExtensionsBrowserClient::CreateExtensionHostDelegate() {
  return std::make_unique<OrbitExtensionHostDelegate>();
}

bool OrbitExtensionsBrowserClient::DidVersionUpdate(
    content::BrowserContext* context) {
  return false;
}

void OrbitExtensionsBrowserClient::PermitExternalProtocolHandler() {}

bool OrbitExtensionsBrowserClient::IsInDemoMode() {
  return false;
}

bool OrbitExtensionsBrowserClient::IsScreensaverInDemoMode(
    const std::string& app_id) {
  return false;
}

bool OrbitExtensionsBrowserClient::IsRunningInForcedAppMode() {
  return false;
}

bool OrbitExtensionsBrowserClient::IsAppModeForcedForApp(
    const extensions::ExtensionId& extension_id) {
  return false;
}

bool OrbitExtensionsBrowserClient::IsLoggedInAsPublicAccount() {
  return false;
}

extensions::ExtensionSystemProvider*
OrbitExtensionsBrowserClient::GetExtensionSystemFactory() {
  return OrbitExtensionSystemFactory::GetInstance();
}

void OrbitExtensionsBrowserClient::RegisterBrowserInterfaceBindersForFrame(
    mojo::BinderMapWithContext<content::RenderFrameHost*>* binder_map,
    content::RenderFrameHost* render_frame_host,
    const extensions::Extension* extension) const {}

std::unique_ptr<extensions::RuntimeAPIDelegate>
OrbitExtensionsBrowserClient::CreateRuntimeAPIDelegate(
    content::BrowserContext* context) const {
  return std::make_unique<OrbitRuntimeAPIDelegate>();
}

const extensions::ComponentExtensionResourceManager*
OrbitExtensionsBrowserClient::GetComponentExtensionResourceManager() {
  return nullptr;
}

void OrbitExtensionsBrowserClient::BroadcastEventToRenderers(
    extensions::events::HistogramValue histogram_value,
    const std::string& event_name,
    base::ListValue args,
    bool dispatch_to_off_the_record_profiles) {
  // A single profile, so "broadcast to every profile" is just this one.
  extensions::EventRouter::Get(browser_context_)
      ->BroadcastEvent(std::make_unique<extensions::Event>(
          histogram_value, event_name, std::move(args)));
}

extensions::ExtensionCache* OrbitExtensionsBrowserClient::GetExtensionCache() {
  return extension_cache_.get();
}

bool OrbitExtensionsBrowserClient::IsBackgroundUpdateAllowed() {
  return false;
}

bool OrbitExtensionsBrowserClient::IsMinBrowserVersionSupported(
    const std::string& min_version) {
  const base::Version& browser_version = version_info::GetVersion();
  base::Version browser_min_version(min_version);
  return !browser_version.IsValid() || !browser_min_version.IsValid() ||
        browser_min_version.CompareTo(browser_version) <= 0;
}

void OrbitExtensionsBrowserClient::CreateExtensionWebContentsObserver(
    content::WebContents* web_contents) {
  OrbitExtensionWebContentsObserver::CreateForWebContents(web_contents);
}

extensions::ExtensionWebContentsObserver*
OrbitExtensionsBrowserClient::GetExtensionWebContentsObserver(
    content::WebContents* web_contents) {
  return OrbitExtensionWebContentsObserver::FromWebContents(web_contents);
}

extensions::KioskDelegate* OrbitExtensionsBrowserClient::GetKioskDelegate() {
  return kiosk_delegate_.get();
}

extensions::SafeBrowsingDelegate*
OrbitExtensionsBrowserClient::GetSafeBrowsingDelegate() {
  return safe_browsing_delegate_.get();
}

std::string OrbitExtensionsBrowserClient::GetApplicationLocale() {
  return l10n_util::GetApplicationLocale(std::string());
}

extensions::ExtensionManagementClient*
OrbitExtensionsBrowserClient::GetExtensionManagementClient(
    content::BrowserContext* context) {
  return extension_management_client_.get();
}

bool OrbitExtensionsBrowserClient::IsExtensionEnabled(
    const extensions::ExtensionId& extension_id,
    content::BrowserContext* context) const {
  return extensions::ExtensionRegistrar::Get(context)->IsExtensionEnabled(extension_id);
}

custom_handlers::ProtocolHandlerRegistry*
OrbitExtensionsBrowserClient::GetProtocolHandlerRegistry(
    content::BrowserContext* context) {
  return static_cast<OrbitBrowserContext*>(context)->protocol_handler_registry();
}

}  // namespace orbit
