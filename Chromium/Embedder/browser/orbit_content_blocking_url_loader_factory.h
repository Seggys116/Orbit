// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_CONTENT_BLOCKING_URL_LOADER_FACTORY_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_CONTENT_BLOCKING_URL_LOADER_FACTORY_H_

#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "mojo/public/cpp/bindings/remote.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/mojom/url_loader_factory.mojom.h"

namespace orbit {

// Asks Swift's ContentBlocker about each request: blocked -> ERR_BLOCKED_BY_CLIENT,
// `$redirect=` -> synthesised 200 response, allowed -> forwarded to `target`.
// The match runs off the UI thread; the class itself otherwise lives on it.
// Self-owned: deletes itself when receivers disconnect.
class OrbitContentBlockingURLLoaderFactory
    : public network::mojom::URLLoaderFactory {
 public:
  // `document_url` is "" where there is no meaningful top-level page.
  // Main-frame navigations bypass the decision: only fetched content is blocked.
  OrbitContentBlockingURLLoaderFactory(
      mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
      mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
      std::string document_url,
      bool is_main_frame_navigation);
  OrbitContentBlockingURLLoaderFactory(
      const OrbitContentBlockingURLLoaderFactory&) = delete;
  OrbitContentBlockingURLLoaderFactory& operator=(
      const OrbitContentBlockingURLLoaderFactory&) = delete;
  ~OrbitContentBlockingURLLoaderFactory() override;

  // network::mojom::URLLoaderFactory:
  void CreateLoaderAndStart(
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      int32_t request_id,
      uint32_t options,
      const network::ResourceRequest& url_request,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const net::MutableNetworkTrafficAnnotationTag& traffic_annotation)
      override;
  void Clone(mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver)
      override;

 private:
  void OnDisconnect();

  // Reply from the DecideContentBlocking call CreateLoaderAndStart posted to
  // a background sequence, back on this object's own (UI) sequence.
  void OnDecision(mojo::PendingReceiver<network::mojom::URLLoader> loader,
                   int32_t request_id,
                   uint32_t options,
                   network::ResourceRequest url_request,
                   mojo::PendingRemote<network::mojom::URLLoaderClient> client,
                   net::MutableNetworkTrafficAnnotationTag traffic_annotation,
                   ContentBlockingRequestDecision decision);

  // Answers `client` with a 200 carrying `body` as `mime_type`, never a
  // redirect. Falls back to ERR_BLOCKED_BY_CLIENT if unservable safely.
  void ServeSubstitution(
      const GURL& request_url,
      mojo::PendingReceiver<network::mojom::URLLoader> loader,
      mojo::PendingRemote<network::mojom::URLLoaderClient> client,
      const std::string& mime_type,
      const std::vector<uint8_t>& body);

  mojo::ReceiverSet<network::mojom::URLLoaderFactory> receivers_;
  mojo::Remote<network::mojom::URLLoaderFactory> target_;
  const std::string document_url_;
  const bool is_main_frame_navigation_;

  // Last: invalidates any in-flight OnDecision reply before the rest of this
  // object is torn down.
  base::WeakPtrFactory<OrbitContentBlockingURLLoaderFactory> weak_factory_{
      this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_CONTENT_BLOCKING_URL_LOADER_FACTORY_H_
