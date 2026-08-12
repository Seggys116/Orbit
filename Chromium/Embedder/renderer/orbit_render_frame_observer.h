// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// One instance per RenderFrame; injects pushed user scripts at document
// start/end and relays the page->native message channel (__orbitPostMessage).

#ifndef ORBIT_EMBEDDER_RENDERER_ORBIT_RENDER_FRAME_OBSERVER_H_
#define ORBIT_EMBEDDER_RENDERER_ORBIT_RENDER_FRAME_OBSERVER_H_

#include <string>
#include <vector>

#include "content/public/renderer/render_frame_observer.h"
#include "content/public/renderer/render_frame_observer_tracker.h"
#include "mojo/public/cpp/bindings/associated_receiver.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/pending_associated_receiver.h"
#include "orbit/common/orbit_mojom.mojom.h"
#include "orbit/common/orbit_user_script_spec.h"
#include "services/service_manager/public/cpp/binder_registry.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_registry.h"

namespace content {
class RenderFrame;
}  // namespace content

namespace orbit {

class OrbitRenderFrameObserver
    : public content::RenderFrameObserver,
      public content::RenderFrameObserverTracker<OrbitRenderFrameObserver>,
      public mojom::UserScriptInjector {
 public:
  explicit OrbitRenderFrameObserver(content::RenderFrame* render_frame);
  OrbitRenderFrameObserver(const OrbitRenderFrameObserver&) = delete;
  OrbitRenderFrameObserver& operator=(const OrbitRenderFrameObserver&) =
      delete;
  ~OrbitRenderFrameObserver() override;

  // Owned home for extensions::ExtensionsRenderFrameObserver's own interfaces
  // (e.g. AppWindow); inert today since Orbit routes only via associated_interfaces_.
  service_manager::BinderRegistry* extensions_binder_registry() {
    return &extensions_binder_registry_;
  }

  // content::RenderFrameObserver:
  void OnDestruct() override;
  void DidClearWindowObject() override;
  bool OnAssociatedInterfaceRequestForFrame(
      const std::string& interface_name,
      mojo::ScopedInterfaceEndpointHandle* handle) override;

  // mojom::UserScriptInjector:
  void SetUserScripts(std::vector<mojom::UserScriptSpecPtr> scripts) override;

  // Driven by RunScriptsAtDocumentEnd, not DidDispatchDOMContentLoadedEvent --
  // see that caller for why the DOMContentLoaded hook can't run script.
  void RunDocumentEndScripts();

 private:
  void BindUserScriptInjector(
      mojo::PendingAssociatedReceiver<mojom::UserScriptInjector> receiver);

  // Installs window.__orbitPostMessage, runs matching document-start scripts,
  // then removes the binding; mirrors MediaSessionObserverScript.swift's source().
  void RunDocumentStartScripts();

  // Bound into window.__orbitPostMessage; forwards to orbit::mojom::
  // ScriptChannel on the browser side.
  void HandlePostMessage(const std::string& channel, const std::string& json);

  std::vector<UserScriptSpec> scripts_;

  service_manager::BinderRegistry extensions_binder_registry_;
  blink::AssociatedInterfaceRegistry associated_interfaces_;
  mojo::AssociatedReceiver<mojom::UserScriptInjector> receiver_{this};
  mojo::AssociatedRemote<mojom::ScriptChannel> script_channel_remote_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_RENDERER_ORBIT_RENDER_FRAME_OBSERVER_H_
