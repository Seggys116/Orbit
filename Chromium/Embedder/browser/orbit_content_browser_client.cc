// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_content_browser_client.h"

#include <string>
#include <utility>
#include <vector>

#include "base/command_line.h"
#include "base/environment.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/supports_user_data.h"
#include "components/os_crypt/async/browser/keychain_key_provider.h"
#include "components/os_crypt/async/browser/os_crypt_async.h"
#include "components/printing/common/print.mojom.h"
#include "content/public/browser/devtools_manager_delegate.h"
#include "content/public/browser/navigation_throttle_registry.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/render_process_host_observer.h"
#include "content/public/browser/overlay_window.h"
#include "content/public/browser/security_principal.h"
#include "content/public/browser/service_worker_version_base_info.h"
#include "content/public/browser/site_instance.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/child_process_id.h"
#include "content/public/common/url_constants.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_browser_context.h"
#include "orbit/browser/orbit_browser_main_parts.h"
#include "orbit/browser/orbit_color_scheme.h"
#include "orbit/browser/orbit_content_blocking_url_loader_factory.h"
#include "orbit/browser/orbit_devtools_manager_delegate.h"
#include "orbit/browser/orbit_http_auth_login_delegate.h"
#include "orbit/browser/orbit_print_manager.h"
#include "orbit/browser/orbit_video_overlay_window_mac.h"
#include "orbit/browser/orbit_web_contents_host.h"
#include "orbit/common/orbit_extensions_client.h"
#include "orbit/common/orbit_user_agent.h"
#include "orbit/common/orbit_user_data_dir.h"
#include "third_party/blink/public/common/web_preferences/web_preferences.h"
#include "extensions/browser/api/web_request/web_request_api.h"
#include "extensions/browser/browser_context_keyed_api_factory.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_navigation_throttle.h"
#include "extensions/browser/extension_protocols.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_web_contents_observer.h"
#include "extensions/browser/process_map.h"
#include "extensions/browser/renderer_startup_helper.h"
#include "extensions/browser/service_worker/service_worker_host.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/event_router.mojom.h"
#include "extensions/common/mojom/frame.mojom.h"
#include "extensions/common/mojom/renderer_host.mojom.h"
#include "extensions/common/mojom/service_worker_host.mojom.h"
#include "net/cookies/site_for_cookies.h"
#include "services/network/public/cpp/cookie_encryption_provider_impl.h"
#include "services/network/public/cpp/url_loader_factory_builder.h"
#include "services/network/public/mojom/network_context.mojom.h"
#include "services/network/public/mojom/web_transport.mojom.h"
#include "services/network/public/mojom/websocket.mojom.h"
#include "services/service_manager/public/cpp/binder_registry.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"

namespace orbit {

namespace {

// Drops a render process's ProcessMap entry when it goes away. Orbit has no
// ExtensionService, so tracking rides on the host as user data instead.
class ExtensionProcessMapEntry : public base::SupportsUserData::Data,
                                 public content::RenderProcessHostObserver {
 public:
  static void Track(content::RenderProcessHost* host) {
    if (host->GetUserData(kUserDataKey)) {
      return;
    }
    host->SetUserData(kUserDataKey,
                      std::make_unique<ExtensionProcessMapEntry>(host));
  }

  explicit ExtensionProcessMapEntry(content::RenderProcessHost* host)
      : host_(host) {
    host_->AddObserver(this);
  }

  ExtensionProcessMapEntry(const ExtensionProcessMapEntry&) = delete;
  ExtensionProcessMapEntry& operator=(const ExtensionProcessMapEntry&) = delete;

  ~ExtensionProcessMapEntry() override {
    if (host_) {
      host_->RemoveObserver(this);
    }
  }

  void RenderProcessHostDestroyed(content::RenderProcessHost* host) override {
    host->RemoveObserver(this);
    host_ = nullptr;
    if (extensions::ProcessMap* process_map =
            extensions::ProcessMap::Get(host->GetBrowserContext())) {
      process_map->Remove(host->GetID());
    }
  }

 private:
  static constexpr char kUserDataKey[] = "OrbitExtensionProcessMapEntry";

  raw_ptr<content::RenderProcessHost> host_;
};

}  // namespace

OrbitContentBrowserClient::OrbitContentBrowserClient() {
  // Runs once, browser-process only. ExtensionsClient must be Set() before
  // anything reads an extension manifest; see orbit_extensions_client.h.
  EnsureExtensionsClientInitialized();

}

// Lazy, not in the ctor: KeychainKeyProvider touches the login keychain
// immediately, which an unsigned/test run with no persistent cookie store
// has no business prompting for. Required once a partition gets a
// persistent cookie store, or network_context.cc NOTREACHEs on mac.
CookieEncryptionProviderImpl*
OrbitContentBrowserClient::GetCookieEncryptionProvider() {
  if (!cookie_encryption_provider_) {
    std::vector<std::pair<os_crypt_async::OSCryptAsync::Precedence,
                          std::unique_ptr<os_crypt_async::KeyProvider>>>
        os_crypt_providers;
    os_crypt_providers.emplace_back(
        10u, std::make_unique<os_crypt_async::KeychainKeyProvider>());
    os_crypt_async_ = std::make_unique<os_crypt_async::OSCryptAsync>(
        std::move(os_crypt_providers));
    cookie_encryption_provider_ =
        std::make_unique<CookieEncryptionProviderImpl>(os_crypt_async_.get());
  }
  return cookie_encryption_provider_.get();
}

OrbitContentBrowserClient::~OrbitContentBrowserClient() = default;

std::unique_ptr<content::BrowserMainParts>
OrbitContentBrowserClient::CreateBrowserMainParts(bool is_integration_test) {
  return std::make_unique<OrbitBrowserMainParts>();
}

void OrbitContentBrowserClient::AppendExtraCommandLineSwitches(
    base::CommandLine* command_line,
    int child_process_id) {
  const base::CommandLine& browser_command_line =
      *base::CommandLine::ForCurrentProcess();
  if (!browser_command_line.HasSwitch(kOrbitUserDataDirSwitch) ||
      command_line->HasSwitch(kOrbitUserDataDirSwitch)) {
    return;
  }
  command_line->AppendSwitchPath(
      kOrbitUserDataDirSwitch,
      browser_command_line.GetSwitchValuePath(kOrbitUserDataDirSwitch));
}

std::vector<base::FilePath>
OrbitContentBrowserClient::GetNetworkContextsParentDirectory() {
  return {OrbitUserDataDir()};
}

base::FilePath OrbitContentBrowserClient::GetLoggingFileName(
    const base::CommandLine& command_line) {
  base::FilePath log_path = command_line.GetSwitchValuePath("log-file");
  if (!log_path.empty()) {
    return log_path;
  }
  return OrbitUserDataDir().Append("Orbit.log");
}

std::string OrbitContentBrowserClient::GetProduct() {
  return orbit::GetProduct();
}

std::string OrbitContentBrowserClient::GetUserAgent() {
  return orbit::GetUserAgent();
}

blink::UserAgentMetadata OrbitContentBrowserClient::GetUserAgentMetadata() {
  return orbit::GetUserAgentMetadata();
}

void OrbitContentBrowserClient::OverrideWebPreferences(
    content::WebContents* web_contents,
    content::SiteInstance& main_frame_site,
    blink::web_pref::WebPreferences* prefs) {
  const blink::mojom::PreferredColorScheme scheme =
      orbit::ColorSchemeIsDark()
          ? blink::mojom::PreferredColorScheme::kDark
          : blink::mojom::PreferredColorScheme::kLight;
  prefs->preferred_color_scheme = scheme;
  prefs->preferred_root_scrollbar_color_scheme = scheme;
}

bool OrbitContentBrowserClient::ShouldEnableStrictSiteIsolation() {
  return true;
}

bool OrbitContentBrowserClient::ShouldDisableSiteIsolation(
    content::SiteIsolationMode site_isolation_mode) {
  return false;
}

void OrbitContentBrowserClient::ConfigureNetworkContextParams(
    content::BrowserContext* context,
    bool in_memory,
    const base::FilePath& relative_partition_path,
    network::mojom::NetworkContextParams* network_context_params,
    cert_verifier::mojom::CertVerifierCreationParams*
        cert_verifier_creation_params) {
  content::ContentBrowserClient::ConfigureNetworkContextParams(
      context, in_memory, relative_partition_path, network_context_params,
      cert_verifier_creation_params);

  network_context_params->http_cache_enabled = true;
  // Base class default leaves this empty; network-service-originated
  // requests must carry the same identity every navigation does.
  network_context_params->user_agent = GetUserAgent();

  // `in_memory` tracks only genuinely-ephemeral partitions (none exist yet);
  // leaving `file_paths` unset forces in-memory-only regardless of http_cache_enabled.
  if (in_memory) {
    return;
  }

  const base::FilePath partition_path =
      OrbitUserDataDir().Append(relative_partition_path);

  network_context_params->file_paths =
      network::mojom::NetworkContextFilePaths::New();
  network_context_params->file_paths->data_directory =
      partition_path.Append("Network");
  network_context_params->file_paths->http_cache_directory =
      partition_path.Append("Cache");
  network_context_params->file_paths->http_server_properties_file_name =
      base::FilePath("Network Persistent State");
  network_context_params->file_paths->cookie_database_name =
      base::FilePath("Cookies");
  // The live-engine test host can't approve the Keychain prompt OSCryptAsync
  // needs, so tests get a plaintext store; a shipped run never takes this branch.
  if (base::Environment::Create()->HasVar("ORBIT_LIVE_ENGINE")) {
    network_context_params->enable_encrypted_cookies = false;
    return;
  }

  // Required the instant cookie_database_name is set -- see the constructor's
  // own comment; NOTREACHEs on mac otherwise.
  network_context_params->cookie_encryption_provider =
      GetCookieEncryptionProvider()->BindNewRemote();
  network_context_params->file_paths->trust_token_database_name =
      base::FilePath("Trust Tokens");
  network_context_params->file_paths->transport_security_persister_file_name =
      base::FilePath("TransportSecurity");
  network_context_params->file_paths->device_bound_sessions_database_name =
      base::FilePath("DeviceBoundSessions");
}

void OrbitContentBrowserClient::RegisterAssociatedInterfaceBindersForRenderFrameHost(
    content::RenderFrameHost& render_frame_host,
    blink::AssociatedInterfaceRegistry& associated_registry) {
  associated_registry.AddInterface<mojom::ScriptChannel>(base::BindRepeating(
      &OrbitContentBrowserClient::BindScriptChannel, base::Unretained(this),
      render_frame_host.GetGlobalId()));
  associated_registry.AddInterface<extensions::mojom::LocalFrameHost>(
      base::BindRepeating(
          [](content::RenderFrameHost* render_frame_host,
             mojo::PendingAssociatedReceiver<extensions::mojom::LocalFrameHost>
                 receiver) {
            extensions::ExtensionWebContentsObserver::BindLocalFrameHost(
                std::move(receiver), render_frame_host);
          },
          &render_frame_host));
  const content::ChildProcessId render_process_id =
      render_frame_host.GetProcess()->GetID();
  associated_registry.AddInterface<extensions::mojom::RendererHost>(
      base::BindRepeating(&extensions::RendererStartupHelper::BindForRenderer,
                          render_process_id));
  associated_registry.AddInterface<extensions::mojom::EventRouter>(
      base::BindRepeating(&extensions::EventRouter::BindForRenderer,
                          render_process_id));
  // print_to_pdf's own PrintManagerHost -- see orbit_print_manager.h.
  associated_registry.AddInterface<printing::mojom::PrintManagerHost>(
      base::BindRepeating(
          [](content::RenderFrameHost* render_frame_host,
             mojo::PendingAssociatedReceiver<printing::mojom::PrintManagerHost>
                 receiver) {
            OrbitPrintManager::BindPrintManagerHost(std::move(receiver),
                                                    render_frame_host);
          },
          &render_frame_host));
}

void OrbitContentBrowserClient::SiteInstanceGotProcessAndSite(
    content::SiteInstance* site_instance) {
  const content::SecurityPrincipal& principal =
      site_instance->GetSecurityPrincipal();
  if (!principal.SchemeIs(extensions::kExtensionScheme) ||
      principal.IsSandboxed()) {
    return;
  }
  content::BrowserContext* browser_context =
      site_instance->GetProcess()->GetBrowserContext();
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(browser_context);
  extensions::ProcessMap* process_map =
      extensions::ProcessMap::Get(browser_context);
  if (!registry || !process_map) {
    return;
  }
  const extensions::Extension* extension =
      registry->enabled_extensions().GetByID(
          extensions::ExtensionId(principal.GetHost()));
  if (!extension) {
    return;
  }
  process_map->Insert(extension->id(), site_instance->GetProcess()->GetID());
  ExtensionProcessMapEntry::Track(site_instance->GetProcess());
}

void OrbitContentBrowserClient::ExposeInterfacesToRenderer(
    service_manager::BinderRegistry* registry,
    blink::AssociatedInterfaceRegistry* associated_registry,
    content::RenderProcessHost* render_process_host) {
  associated_registry->AddInterface<extensions::mojom::RendererHost>(
      base::BindRepeating(&extensions::RendererStartupHelper::BindForRenderer,
                          render_process_host->GetID()));
}

void OrbitContentBrowserClient::RegisterAssociatedInterfaceBindersForServiceWorker(
    const content::ServiceWorkerVersionBaseInfo& service_worker_version_info,
    blink::AssociatedInterfaceRegistry& associated_registry) {
  const content::ChildProcessId render_process_id =
      service_worker_version_info.process_id;
  associated_registry.AddInterface<extensions::mojom::RendererHost>(
      base::BindRepeating(&extensions::RendererStartupHelper::BindForRenderer,
                          render_process_id));
  associated_registry.AddInterface<extensions::mojom::ServiceWorkerHost>(
      base::BindRepeating(&extensions::ServiceWorkerHost::BindReceiver,
                          render_process_id));
  associated_registry.AddInterface<extensions::mojom::EventRouter>(
      base::BindRepeating(&extensions::EventRouter::BindForRenderer,
                          render_process_id));
}

mojo::PendingRemote<network::mojom::URLLoaderFactory>
OrbitContentBrowserClient::CreateNonNetworkNavigationURLLoaderFactory(
    const std::string& scheme,
    content::FrameTreeNodeId frame_tree_node_id) {
  if (scheme != extensions::kExtensionScheme) {
    return {};
  }
  content::WebContents* web_contents =
      content::WebContents::FromFrameTreeNodeId(frame_tree_node_id);
  if (!web_contents) {
    return {};
  }
  return extensions::CreateExtensionNavigationURLLoaderFactory(
      web_contents->GetBrowserContext(), /*is_web_view_request=*/false);
}

void OrbitContentBrowserClient::RegisterNonNetworkWorkerMainResourceURLLoaderFactories(
    content::BrowserContext* browser_context,
    const std::optional<url::Origin>& request_initiator,
    network::mojom::RequestDestination request_destination,
    NonNetworkURLLoaderFactoryMap* factories) {
  factories->emplace(extensions::kExtensionScheme,
                     extensions::CreateExtensionWorkerMainResourceURLLoaderFactory(
                         browser_context, request_initiator));
}

void OrbitContentBrowserClient::RegisterNonNetworkServiceWorkerUpdateURLLoaderFactories(
    content::BrowserContext* browser_context,
    NonNetworkURLLoaderFactoryMap* factories) {
  factories->emplace(extensions::kExtensionScheme,
                     extensions::CreateExtensionServiceWorkerScriptURLLoaderFactory(
                         browser_context));
}

void OrbitContentBrowserClient::RegisterNonNetworkSubresourceURLLoaderFactories(
    int render_process_id,
    int render_frame_id,
    const std::optional<url::Origin>& request_initiator_origin,
    NonNetworkURLLoaderFactoryMap* factories) {
  factories->emplace(
      extensions::kExtensionScheme,
      extensions::CreateExtensionURLLoaderFactory(
          content::ChildProcessId::FromUnsafeValue(render_process_id), render_frame_id));
}

void OrbitContentBrowserClient::WillCreateURLLoaderFactory(
    content::BrowserContext* browser_context,
    content::RenderFrameHost* frame,
    int render_process_id,
    URLLoaderFactoryType type,
    const url::Origin& request_initiator,
    const net::IsolationInfo& isolation_info,
    std::optional<int64_t> navigation_id,
    ukm::SourceIdObj ukm_source_id,
    network::URLLoaderFactoryBuilder& factory_builder,
    mojo::PendingRemote<network::mojom::TrustedURLLoaderHeaderClient>*
        header_client,
    bool* bypass_redirect_checks,
    bool* disable_secure_dns,
    network::mojom::URLLoaderFactoryOverridePtr* factory_override,
    scoped_refptr<base::SequencedTaskRunner> navigation_response_task_runner) {
  // webRequest goes first and outside the guards below: it must still see
  // requests when there's no content blocker; composes with the blocker below.
  auto* web_request_api =
      extensions::BrowserContextKeyedAPIFactory<extensions::WebRequestAPI>::Get(
          browser_context);
  if (web_request_api) {
    const bool proxying = web_request_api->MaybeProxyURLLoaderFactory(
        browser_context, frame, render_process_id, type,
        std::move(navigation_id), ukm_source_id, factory_builder, header_client,
        navigation_response_task_runner, request_initiator);
    if (bypass_redirect_checks) {
      *bypass_redirect_checks = proxying;
    }
  }

  // No active blocker: skip installing the interceptor entirely, not merely
  // an always-allow one, since every request on every page pays for it.
  if (!IsContentBlockingActive()) {
    return;
  }

  // Only factory types carrying requests the filter lists can match.
  switch (type) {
    case URLLoaderFactoryType::kNavigation:
    case URLLoaderFactoryType::kDocumentSubResource:
    case URLLoaderFactoryType::kWorkerMainResource:
    case URLLoaderFactoryType::kWorkerSubResource:
    case URLLoaderFactoryType::kServiceWorkerSubResource:
      break;
    default:
      return;
  }

  // A null frame on a navigation means we cannot tell main from sub; bypass,
  // because wrongly blocking the page the user asked for is the worse failure.
  const bool is_main_frame_navigation =
      type == URLLoaderFactoryType::kNavigation &&
      (!frame || !frame->GetParent());

  // The top-level page, for third-party/allowlist matching -- not `frame`'s
  // own URL, which for a subframe request is the wrong document.
  std::string document_url;
  if (frame && frame->GetOutermostMainFrame()) {
    document_url = frame->GetOutermostMainFrame()->GetLastCommittedURL().spec();
  }

  auto [receiver, remote] = factory_builder.Append();
  new OrbitContentBlockingURLLoaderFactory(std::move(receiver),
                                           std::move(remote), document_url,
                                           is_main_frame_navigation);
}

void OrbitContentBrowserClient::CreateThrottlesForNavigation(
    content::NavigationThrottleRegistry& registry) {
  registry.AddThrottle(
      std::make_unique<extensions::ExtensionNavigationThrottle>(registry));
}

bool OrbitContentBrowserClient::WillInterceptWebSocket(
    content::RenderFrameHost* frame) {
  if (!frame) {
    return false;
  }
  auto* web_request_api =
      extensions::BrowserContextKeyedAPIFactory<extensions::WebRequestAPI>::Get(
          frame->GetBrowserContext());
  return web_request_api && web_request_api->MayHaveProxiesForFrame(frame);
}

void OrbitContentBrowserClient::CreateWebSocket(
    content::RenderFrameHost* frame,
    WebSocketFactory factory,
    const GURL& url,
    const net::SiteForCookies& site_for_cookies,
    const std::optional<std::string>& user_agent,
    mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
        handshake_client,
    WebSocketOptions options) {
  // Only reachable because WillInterceptWebSocket returned true, which
  // already established both the frame and the proxy.
  auto* web_request_api =
      extensions::BrowserContextKeyedAPIFactory<extensions::WebRequestAPI>::Get(
          frame->GetBrowserContext());
  web_request_api->ProxyWebSocket(frame, std::move(factory), url,
                                  site_for_cookies, user_agent,
                                  std::move(handshake_client),
                                  std::move(options.header_client));
}

void OrbitContentBrowserClient::WillCreateWebTransport(
    int process_id,
    int frame_routing_id,
    const GURL& url,
    const url::Origin& initiator_origin,
    mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>
        handshake_client,
    WillCreateWebTransportCallback callback) {
  auto* render_process_host = content::RenderProcessHost::FromID(process_id);
  if (!render_process_host) {
    std::move(callback).Run(std::move(handshake_client), std::nullopt);
    return;
  }
  auto* web_request_api =
      extensions::BrowserContextKeyedAPIFactory<extensions::WebRequestAPI>::Get(
          render_process_host->GetBrowserContext());
  if (!web_request_api) {
    std::move(callback).Run(std::move(handshake_client), std::nullopt);
    return;
  }
  web_request_api->ProxyWebTransport(*render_process_host, frame_routing_id,
                                     url, initiator_origin,
                                     std::move(handshake_client),
                                     std::move(callback));
}

std::unique_ptr<content::LoginDelegate>
OrbitContentBrowserClient::CreateLoginDelegate(
    const net::AuthChallengeInfo& auth_info,
    content::WebContents* web_contents,
    content::BrowserContext* browser_context,
    const content::GlobalRequestID& request_id,
    bool is_request_for_primary_main_frame_navigation,
    bool is_request_for_navigation,
    const GURL& url,
    scoped_refptr<net::HttpResponseHeaders> response_headers,
    bool first_auth_attempt,
    content::GuestPageHolder* guest_page_holder,
    content::LoginDelegate::LoginAuthRequiredCallback auth_required_callback) {
  return std::make_unique<OrbitHttpAuthLoginDelegate>(
      browser_context, auth_info, std::move(response_headers), request_id,
      is_request_for_navigation, std::move(auth_required_callback));
}

void OrbitContentBrowserClient::AllowCertificateError(
    content::WebContents* web_contents,
    int cert_error,
    const net::SSLInfo& ssl_info,
    const GURL& request_url,
    bool is_primary_main_frame_request,
    bool strict_enforcement,
    base::OnceCallback<void(content::CertificateRequestResultType)> callback) {
  if (callback.is_null()) {
    return;
  }
  // Anything but the primary main frame (subresource, subframe, prerender,
  // fenced frame) is blocked outright: no page-level context to answer in.
  if (!is_primary_main_frame_request || !web_contents) {
    std::move(callback).Run(content::CERTIFICATE_REQUEST_RESULT_TYPE_DENY);
    return;
  }
  // No host means a WebContents Orbit's UI does not own (a devtools-internal
  // one, say). Nothing can present an interstitial for it, so it is denied.
  OrbitWebContentsHost* host =
      OrbitWebContentsHost::FromWebContents(web_contents);
  if (!host) {
    std::move(callback).Run(content::CERTIFICATE_REQUEST_RESULT_TYPE_DENY);
    return;
  }
  host->HandleCertificateError(cert_error, ssl_info, request_url,
                               strict_enforcement, std::move(callback));
}

void OrbitContentBrowserClient::GetAdditionalWebUISchemes(
    std::vector<std::string>* additional_schemes) {
  additional_schemes->push_back(content::kChromeDevToolsScheme);
}

std::unique_ptr<content::DevToolsManagerDelegate>
OrbitContentBrowserClient::CreateDevToolsManagerDelegate() {
  return std::make_unique<OrbitDevToolsManagerDelegate>();
}

std::unique_ptr<content::VideoOverlayWindow>
OrbitContentBrowserClient::CreateWindowForVideoPictureInPicture(
    content::VideoPictureInPictureWindowController* controller) {
  return CreateVideoOverlayWindowMac(controller);
}

void OrbitContentBrowserClient::BindScriptChannel(
    content::GlobalRenderFrameHostId frame_id,
    mojo::PendingAssociatedReceiver<mojom::ScriptChannel> receiver) {
  content::RenderFrameHost* render_frame_host =
      content::RenderFrameHost::FromID(frame_id);
  if (!render_frame_host) {
    return;
  }
  content::WebContents* web_contents =
      content::WebContents::FromRenderFrameHost(render_frame_host);
  if (!web_contents) {
    return;
  }
  OrbitWebContentsHost* host = OrbitWebContentsHost::FromWebContents(web_contents);
  if (!host) {
    return;
  }
  host->BindScriptChannel(render_frame_host, std::move(receiver));
}

}  // namespace orbit
