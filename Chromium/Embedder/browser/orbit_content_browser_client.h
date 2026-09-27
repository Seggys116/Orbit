// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_CONTENT_BROWSER_CLIENT_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_CONTENT_BROWSER_CLIENT_H_

#include <memory>
#include <string>

#include "content/public/browser/content_browser_client.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/overlay_window.h"
#include "mojo/public/cpp/bindings/pending_associated_receiver.h"
#include "orbit/common/orbit_mojom.mojom.h"

namespace blink {
class AssociatedInterfaceRegistry;
}  // namespace blink

namespace os_crypt_async {
class OSCryptAsync;
}  // namespace os_crypt_async

class CookieEncryptionProviderImpl;

namespace orbit {

class OrbitWebAuthenticationDelegate;

// Orbit's content::ContentBrowserClient. Only overrides that are security
// load-bearing per the sandbox/process design are implemented; see Chromium/README.md.
class OrbitContentBrowserClient : public content::ContentBrowserClient {
 public:
  OrbitContentBrowserClient();
  OrbitContentBrowserClient(const OrbitContentBrowserClient&) = delete;
  OrbitContentBrowserClient& operator=(const OrbitContentBrowserClient&) =
      delete;
  ~OrbitContentBrowserClient() override;

  // content::ContentBrowserClient:

  // CreateBrowserMainParts creates OrbitBrowserMainParts, owner of the single
  // OrbitBrowserContext. This lazily builds the cookie encryption provider
  // on first use, not in the constructor -- see the .cc for why.
  CookieEncryptionProviderImpl* GetCookieEncryptionProvider();

  std::unique_ptr<content::BrowserMainParts> CreateBrowserMainParts(
      bool is_integration_test) override;

  // Carries --orbit-user-data-dir onto every child process command line so
  // helpers resolve the same profile directory instead of the production default.
  void AppendExtraCommandLineSwitches(base::CommandLine* command_line,
                                      int child_process_id) override;

  // Feeds SetupNetworkSandboxParameters(), granting the sandboxed network
  // service read/write to exactly these dirs. Too narrow breaks persistence,
  // too wide leaks the rest of the profile.
  std::vector<base::FilePath> GetNetworkContextsParentDirectory() override;

  // Feeds kParamLogFilePath in the sandbox profile; without it a sandboxed
  // child writing the log Orbit told it to use is denied.
  base::FilePath GetLoggingFileName(
      const base::CommandLine& command_line) override;

  // Base class returns empty/brandless values, reaching pages as empty
  // navigator.userAgent(Data); see orbit/common/orbit_user_agent.h instead.
  std::string GetProduct() override;
  std::string GetUserAgent() override;
  blink::UserAgentMetadata GetUserAgentMetadata() override;

  // Site isolation is pinned explicitly, not left to the overridable platform
  // default. Also answers prefers-color-scheme; see orbit_color_scheme.h.
  void OverrideWebPreferences(content::WebContents* web_contents,
                              content::SiteInstance& main_frame_site,
                              blink::web_pref::WebPreferences* prefs) override;

  bool ShouldEnableStrictSiteIsolation() override;
  bool ShouldDisableSiteIsolation(
      content::SiteIsolationMode site_isolation_mode) override;

  std::string GetAcceptLangs(content::BrowserContext* context) override;

  // Chains onto the base default, then points each on-disk partition's HTTP
  // cache and persisted state (cookies, HSTS...) at real files under
  // OrbitUserDataDir(); unset `file_paths` means in-memory-only.
  void ConfigureNetworkContextParams(
      content::BrowserContext* context,
      bool in_memory,
      const base::FilePath& relative_partition_path,
      network::mojom::NetworkContextParams* network_context_params,
      cert_verifier::mojom::CertVerifierCreationParams*
          cert_verifier_creation_params) override;

  // Exposes ScriptChannel, LocalFrameHost, EventRouter and RendererHost to
  // every RenderFrame; receivers live in orbit_web_contents_host.h and
  // ExtensionWebContentsObserver::BindLocalFrameHost, this only routes binds.
  void RegisterAssociatedInterfaceBindersForRenderFrameHost(
      content::RenderFrameHost& render_frame_host,
      blink::AssociatedInterfaceRegistry& associated_registry) override;

  // Records "this render process hosts this extension" in extensions::ProcessMap,
  // otherwise never written -- without it every privileged extension request
  // and even the extension's own subresource loads are rejected.
  void SiteInstanceGotProcessAndSite(
      content::SiteInstance* site_instance) override;

  // RendererHost, on the process's own channel (Dispatcher reaches it from
  // the main render thread). GetMessageBundle is synchronous: an unbound
  // receiver hangs the caller rather than failing.
  void ExposeInterfacesToRenderer(
      service_manager::BinderRegistry* registry,
      blink::AssociatedInterfaceRegistry* associated_registry,
      content::RenderProcessHost* render_process_host) override;

  // An extension service worker has no RenderFrameHost, so the frame-scoped
  // binders above can't reach it; its API calls and listeners arrive here.
  void RegisterAssociatedInterfaceBindersForServiceWorker(
      const content::ServiceWorkerVersionBaseInfo& service_worker_version_info,
      blink::AssociatedInterfaceRegistry& associated_registry) override;

  // The chrome-extension:// scheme's four non-network URLLoaderFactory hooks;
  // real work (resource lookup, web_accessible_resources checks) lives in
  // extensions/browser/extension_protocols.h.
  mojo::PendingRemote<network::mojom::URLLoaderFactory>
  CreateNonNetworkNavigationURLLoaderFactory(
      const std::string& scheme,
      content::FrameTreeNodeId frame_tree_node_id) override;
  void RegisterNonNetworkWorkerMainResourceURLLoaderFactories(
      content::BrowserContext* browser_context,
      const std::optional<url::Origin>& request_initiator,
      network::mojom::RequestDestination request_destination,
      NonNetworkURLLoaderFactoryMap* factories) override;
  void RegisterNonNetworkServiceWorkerUpdateURLLoaderFactories(
      content::BrowserContext* browser_context,
      NonNetworkURLLoaderFactoryMap* factories) override;
  void RegisterNonNetworkSubresourceURLLoaderFactories(
      int render_process_id,
      int render_frame_id,
      const std::optional<url::Origin>& request_initiator_origin,
      NonNetworkURLLoaderFactoryMap* factories) override;

  // Inserts OrbitContentBlockingURLLoaderFactory ahead of every factory type
  // Orbit's filter lists can match (navigations, subresources, worker scripts).
  void WillCreateURLLoaderFactory(
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
      scoped_refptr<base::SequencedTaskRunner> navigation_response_task_runner)
      override;

  // Adds ExtensionNavigationThrottle, the only enforcer of
  // web_accessible_resources for navigations; without it any page could
  // iframe chrome-extension://<any id>/<any path>. Deliberately minus the
  // UserScriptListener throttle (Orbit's GetUserScriptListener is nullptr),
  // which upstream also uses to block navigations to unknown/disabled
  // extensions and cross-process blob:/filesystem: chrome-extension URLs.
  void CreateThrottlesForNavigation(
      content::NavigationThrottleRegistry& registry) override;

  // ws://, wss:// and WebTransport: the only entry points for webRequest and
  // declarativeNetRequest on these, since WillCreateURLLoaderFactory never
  // sees them. WillInterceptWebSocket must return true or content:: NOTREACHED()s.
  bool WillInterceptWebSocket(content::RenderFrameHost* frame) override;
  void CreateWebSocket(
      content::RenderFrameHost* frame,
      WebSocketFactory factory,
      const GURL& url,
      const net::SiteForCookies& site_for_cookies,
      const std::optional<std::string>& user_agent,
      mojo::PendingRemote<network::mojom::WebSocketHandshakeClient>
          handshake_client,
      WebSocketOptions options) override;
  void WillCreateWebTransport(
      int process_id,
      int frame_routing_id,
      const GURL& url,
      const url::Origin& initiator_origin,
      mojo::PendingRemote<network::mojom::WebTransportHandshakeClient>
          handshake_client,
      WillCreateWebTransportCallback callback) override;

  // Base class returns nullptr, silently resolving 401/407 with no
  // credentials and leaving webRequest.onAuthRequired dead. See
  // orbit_http_auth_login_delegate.h.
  std::unique_ptr<content::LoginDelegate> CreateLoginDelegate(
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
      content::LoginDelegate::LoginAuthRequiredCallback auth_required_callback)
      override;

  // Base class denies every cert error unconditionally; this routes primary
  // main-frame errors to Swift's CertificateInterstitialView, denies the
  // rest. `callback` must run exactly once or content:: hangs the request.
  void AllowCertificateError(
      content::WebContents* web_contents,
      int cert_error,
      const net::SSLInfo& ssl_info,
      const GURL& request_url,
      bool is_primary_main_frame_request,
      bool strict_enforcement,
      base::OnceCallback<void(content::CertificateRequestResultType)> callback)
      override;

  // Adds devtools:// to URLDataManagerBackend's WebUI scheme list, required
  // before OrbitDevToolsDataSource can be asked for the bundled inspector.
  void GetAdditionalWebUISchemes(
      std::vector<std::string>* additional_schemes) override;

  // OrbitDevToolsManagerDelegate; see its own header for what is deliberately
  // absent (any remote debugging server).
  std::unique_ptr<content::DevToolsManagerDelegate>
  CreateDevToolsManagerDelegate() override;

  // Base class returns a default WebAuthenticationDelegate whose
  // GetTouchIdAuthenticatorConfig is nullopt, which disables the platform
  // authenticator outright; see orbit_web_authentication_delegate.h.
  content::WebAuthenticationDelegate* GetWebAuthenticationDelegate() override;

  // Floating AppKit panel PiP is presented in. Base class returns nullptr,
  // which StartSession dereferences unconditionally, so this must land
  // together with OrbitWebContentsHost::EnterPictureInPicture.
  std::unique_ptr<content::VideoOverlayWindow>
  CreateWindowForVideoPictureInPicture(
      content::VideoPictureInPictureWindowController* controller) override;

 private:
  void BindScriptChannel(
      content::GlobalRenderFrameHostId frame_id,
      mojo::PendingAssociatedReceiver<mojom::ScriptChannel> receiver);

  // Built in the constructor with a KeychainKeyProvider so
  // ConfigureNetworkContextParams can hand each partition a real
  // cookie_encryption_provider. Process-lifetime, like this object.
  std::unique_ptr<os_crypt_async::OSCryptAsync> os_crypt_async_;
  std::unique_ptr<CookieEncryptionProviderImpl> cookie_encryption_provider_;

  std::unique_ptr<OrbitWebAuthenticationDelegate> web_authentication_delegate_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_CONTENT_BROWSER_CLIENT_H_
