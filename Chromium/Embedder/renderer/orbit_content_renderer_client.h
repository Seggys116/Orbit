// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_RENDERER_ORBIT_CONTENT_RENDERER_CLIENT_H_
#define ORBIT_EMBEDDER_RENDERER_ORBIT_CONTENT_RENDERER_CLIENT_H_

#include <memory>

#include "content/public/renderer/content_renderer_client.h"

namespace orbit {

class OrbitExtensionsRendererClient;

// Orbit's content::ContentRendererClient: attaches OrbitRenderFrameObserver to
// each RenderFrame and stands up extensions::Dispatcher/ExtensionsRendererClient.
class OrbitContentRendererClient : public content::ContentRendererClient {
 public:
  OrbitContentRendererClient();
  OrbitContentRendererClient(const OrbitContentRendererClient&) = delete;
  OrbitContentRendererClient& operator=(const OrbitContentRendererClient&) =
      delete;
  ~OrbitContentRendererClient() override;

  // content::ContentRendererClient:
  void RenderThreadStarted() override;
  // Without this, service worker contexts get an empty v8::ExtensionConfiguration
  // and SafeBuiltins::GetArray() CHECK-fails on the first chrome.* binding (e.g. webRequest).
  bool AllowScriptExtensionForServiceWorker(
      const url::Origin& script_origin) override;
  // Without this, no ExtensionWebViewHelper is attached and the content-script
  // injection path dereferences null on every page load.
  void WebViewCreated(blink::WebView* web_view,
                      bool was_created_by_renderer,
                      const url::Origin* outermost_origin) override;
  void RenderFrameCreated(content::RenderFrame* render_frame) override;
  void RunScriptsAtDocumentStart(content::RenderFrame* render_frame) override;
  void RunScriptsAtDocumentEnd(content::RenderFrame* render_frame) override;
  void RunScriptsAtDocumentIdle(content::RenderFrame* render_frame) override;

  // Without these an MV3 background service worker evaluates with no chrome.*
  // bindings; WillEvaluateServiceWorkerOnWorkerThread is what installs them.
  void DidInitializeServiceWorkerContextOnWorkerThread(
      blink::WebServiceWorkerContextProxy* context_proxy,
      const GURL& service_worker_scope,
      const GURL& script_url) override;
  void WillEvaluateServiceWorkerOnWorkerThread(
      blink::WebServiceWorkerContextProxy* context_proxy,
      v8::Local<v8::Context> v8_context,
      int64_t service_worker_version_id,
      const GURL& service_worker_scope,
      const GURL& script_url,
      const blink::ServiceWorkerToken& service_worker_token) override;
  void DidStartServiceWorkerContextOnWorkerThread(
      int64_t service_worker_version_id,
      const GURL& service_worker_scope,
      const GURL& script_url,
      const blink::ServiceWorkerToken& service_worker_token) override;
  void WillDestroyServiceWorkerContextOnWorkerThread(
      v8::Local<v8::Context> v8_context,
      int64_t service_worker_version_id,
      const GURL& service_worker_scope,
      const GURL& script_url,
      const blink::ServiceWorkerToken& service_worker_token) override;

 private:
  std::unique_ptr<OrbitExtensionsRendererClient> extensions_renderer_client_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_RENDERER_ORBIT_CONTENT_RENDERER_CLIENT_H_
