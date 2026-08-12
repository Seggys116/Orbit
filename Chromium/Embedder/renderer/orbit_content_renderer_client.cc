// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_content_renderer_client.h"

#include "extensions/common/constants.h"
#include "extensions/renderer/dispatcher.h"
#include "extensions/renderer/extensions_renderer_client.h"
#include "orbit/common/orbit_extensions_client.h"
#include "orbit/renderer/orbit_extensions_renderer_api_provider.h"
#include "orbit/renderer/orbit_extensions_renderer_client.h"
#include "orbit/renderer/orbit_render_frame_observer.h"
#include "url/origin.h"

namespace orbit {

OrbitContentRendererClient::OrbitContentRendererClient() = default;
OrbitContentRendererClient::~OrbitContentRendererClient() = default;

void OrbitContentRendererClient::RenderThreadStarted() {
  // extensions::ExtensionsClient is a browser+renderer singleton; the browser
  // side sets it in OrbitContentBrowserClient's constructor.
  EnsureExtensionsClientInitialized();
  extensions_renderer_client_ = std::make_unique<OrbitExtensionsRendererClient>();
  extensions_renderer_client_->AddAPIProvider(
      std::make_unique<OrbitExtensionsRendererAPIProvider>());
  extensions_renderer_client_->RenderThreadStarted();
}

bool OrbitContentRendererClient::AllowScriptExtensionForServiceWorker(
    const url::Origin& script_origin) {
  return script_origin.scheme() == extensions::kExtensionScheme;
}

void OrbitContentRendererClient::WebViewCreated(
    blink::WebView* web_view,
    bool was_created_by_renderer,
    const url::Origin* outermost_origin) {
  extensions::ExtensionsRendererClient::Get()->WebViewCreated(web_view,
                                                              outermost_origin);
}

void OrbitContentRendererClient::RenderFrameCreated(
    content::RenderFrame* render_frame) {
  // Self-deleting: OrbitRenderFrameObserver::OnDestruct() runs when
  // render_frame is destroyed.
  auto* observer = new OrbitRenderFrameObserver(render_frame);
  extensions::ExtensionsRendererClient::Get()->RenderFrameCreated(
      render_frame, observer->extensions_binder_registry());
}

void OrbitContentRendererClient::RunScriptsAtDocumentStart(
    content::RenderFrame* render_frame) {
  extensions::ExtensionsRendererClient::Get()->RunScriptsAtDocumentStart(render_frame);
}

void OrbitContentRendererClient::RunScriptsAtDocumentEnd(
    content::RenderFrame* render_frame) {
  // Not DidDispatchDOMContentLoadedEvent: content:: fires that inside a
  // ScriptForbiddenScope, so document-end scripts can't run there; use this hook instead.
  if (OrbitRenderFrameObserver* observer =
          OrbitRenderFrameObserver::Get(render_frame)) {
    observer->RunDocumentEndScripts();
  }
  extensions::ExtensionsRendererClient::Get()->RunScriptsAtDocumentEnd(render_frame);
}

void OrbitContentRendererClient::RunScriptsAtDocumentIdle(
    content::RenderFrame* render_frame) {
  extensions::ExtensionsRendererClient::Get()->RunScriptsAtDocumentIdle(render_frame);
}

void OrbitContentRendererClient::DidInitializeServiceWorkerContextOnWorkerThread(
    blink::WebServiceWorkerContextProxy* context_proxy,
    const GURL& service_worker_scope,
    const GURL& script_url) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->DidInitializeServiceWorkerContextOnWorkerThread(
          context_proxy, service_worker_scope, script_url);
}

void OrbitContentRendererClient::WillEvaluateServiceWorkerOnWorkerThread(
    blink::WebServiceWorkerContextProxy* context_proxy,
    v8::Local<v8::Context> v8_context,
    int64_t service_worker_version_id,
    const GURL& service_worker_scope,
    const GURL& script_url,
    const blink::ServiceWorkerToken& service_worker_token) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->WillEvaluateServiceWorkerOnWorkerThread(
          context_proxy, v8_context, service_worker_version_id,
          service_worker_scope, script_url, service_worker_token);
}

void OrbitContentRendererClient::DidStartServiceWorkerContextOnWorkerThread(
    int64_t service_worker_version_id,
    const GURL& service_worker_scope,
    const GURL& script_url,
    const blink::ServiceWorkerToken& service_worker_token) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->DidStartServiceWorkerContextOnWorkerThread(
          service_worker_version_id, service_worker_scope, script_url,
          service_worker_token);
}

void OrbitContentRendererClient::WillDestroyServiceWorkerContextOnWorkerThread(
    v8::Local<v8::Context> v8_context,
    int64_t service_worker_version_id,
    const GURL& service_worker_scope,
    const GURL& script_url,
    const blink::ServiceWorkerToken& service_worker_token) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->WillDestroyServiceWorkerContextOnWorkerThread(
          v8_context, service_worker_version_id, service_worker_scope,
          script_url, service_worker_token);
}

}  // namespace orbit
