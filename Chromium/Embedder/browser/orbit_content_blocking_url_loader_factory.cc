// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_content_blocking_url_loader_factory.h"

#include <algorithm>
#include <optional>
#include <string_view>
#include <utility>

#include "base/byte_size.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/numerics/safe_conversions.h"
#include "base/strings/stringprintf.h"
#include "base/task/task_traits.h"
#include "base/task/thread_pool.h"
#include "base/time/time.h"
#include "mojo/public/cpp/bindings/pending_remote.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "mojo/public/cpp/system/data_pipe.h"
#include "net/base/net_errors.h"
#include "net/base/request_priority.h"
#include "net/http/http_response_headers.h"
#include "net/http/http_util.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "services/network/public/cpp/http_request_headers_update_params.h"
#include "services/network/public/cpp/parsed_headers.h"
#include "services/network/public/cpp/resource_request.h"
#include "services/network/public/cpp/url_loader_completion_status.h"
#include "services/network/public/mojom/url_loader.mojom.h"
#include "services/network/public/mojom/url_response_head.mojom.h"
#include "services/network/public/mojom/fetch_api.mojom.h"
#include "url/gurl.h"

namespace orbit {

namespace {

// Mirrors Orbit/Engine/ContentBlocking/ContentBlockingTypes.swift's
// ContentBlockingResourceType raw values -- do not renumber independently.
enum class OrbitResourceType {
  kDocument = 0,
  kSubdocument = 1,
  kStylesheet = 2,
  kScript = 3,
  kImage = 4,
  kFont = 5,
  kObject = 6,
  kMedia = 7,
  kXMLHttpRequest = 8,
  kPing = 9,
  kWebSocket = 10,
  kCSPReport = 11,
  kOther = 12,
};

// Fetch's "destination" collapses XHR and fetch() into kEmpty; keepalive is
// the one signal left to tell a beacon/ping apart from an ordinary XHR.
OrbitResourceType ResourceTypeForRequest(
    const network::ResourceRequest& request) {
  switch (request.destination) {
    case network::mojom::RequestDestination::kDocument:
    case network::mojom::RequestDestination::kFencedframe:
      return OrbitResourceType::kDocument;
    case network::mojom::RequestDestination::kFrame:
    case network::mojom::RequestDestination::kIframe:
      return OrbitResourceType::kSubdocument;
    case network::mojom::RequestDestination::kStyle:
      return OrbitResourceType::kStylesheet;
    case network::mojom::RequestDestination::kScript:
    case network::mojom::RequestDestination::kServiceWorker:
    case network::mojom::RequestDestination::kSharedWorker:
    case network::mojom::RequestDestination::kWorker:
    case network::mojom::RequestDestination::kWebBundle:
    case network::mojom::RequestDestination::kXslt:
      return OrbitResourceType::kScript;
    case network::mojom::RequestDestination::kImage:
      return OrbitResourceType::kImage;
    case network::mojom::RequestDestination::kFont:
      return OrbitResourceType::kFont;
    case network::mojom::RequestDestination::kObject:
    case network::mojom::RequestDestination::kEmbed:
      return OrbitResourceType::kObject;
    case network::mojom::RequestDestination::kAudio:
    case network::mojom::RequestDestination::kVideo:
    case network::mojom::RequestDestination::kTrack:
    case network::mojom::RequestDestination::kAudioWorklet:
    case network::mojom::RequestDestination::kPaintWorklet:
      return OrbitResourceType::kMedia;
    case network::mojom::RequestDestination::kReport:
      return OrbitResourceType::kCSPReport;
    case network::mojom::RequestDestination::kEmpty:
      return request.keepalive ? OrbitResourceType::kPing
                               : OrbitResourceType::kXMLHttpRequest;
    default:
      return OrbitResourceType::kOther;
  }
}

// Every bundled stub is a few hundred bytes to a few kilobytes; anything past
// this is not one of ours, and would be written into a single data pipe.
constexpr size_t kMaxSubstitutionBodyBytes = 1024 * 1024;

// Interpolated into a response header: a ';', quote, CR or LF would forge
// further headers, so this must be exactly two RFC 9110 tokens around one '/'.
bool IsWellFormedMimeType(const std::string& mime_type) {
  const size_t slash = mime_type.find('/');
  if (slash == std::string::npos || slash == 0 ||
      slash + 1 == mime_type.size() ||
      mime_type.find('/', slash + 1) != std::string::npos) {
    return false;
  }
  return std::all_of(mime_type.begin(), mime_type.end(), [](char c) {
    return c == '/' || net::HttpUtil::IsTokenChar(c);
  });
}

// Holds the URLLoader end of a synthesised response open until the client
// drops it; dropping it ourselves would race OnComplete. Self-owned.
class StubURLLoader : public network::mojom::URLLoader {
 public:
  static void Bind(mojo::PendingReceiver<network::mojom::URLLoader> receiver) {
    if (!receiver.is_valid()) {
      return;
    }
    new StubURLLoader(std::move(receiver));
  }

  StubURLLoader(const StubURLLoader&) = delete;
  StubURLLoader& operator=(const StubURLLoader&) = delete;

 private:
  explicit StubURLLoader(
      mojo::PendingReceiver<network::mojom::URLLoader> receiver)
      : receiver_(this, std::move(receiver)) {
    receiver_.set_disconnect_handler(base::BindOnce(
        [](StubURLLoader* self) { delete self; }, base::Unretained(this)));
  }
  ~StubURLLoader() override = default;

  // network::mojom::URLLoader -- the whole response was delivered before this
  // was bound, so there is nothing left for either call to act on.
  void FollowRedirect(
      network::HttpRequestHeadersUpdateParams headers_update_params,
      const std::optional<GURL>& new_url) override {}
  void SetPriority(net::RequestPriority priority,
                   int32_t intra_priority_value) override {}

  mojo::Receiver<network::mojom::URLLoader> receiver_;
};

}  // namespace

OrbitContentBlockingURLLoaderFactory::OrbitContentBlockingURLLoaderFactory(
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver,
    mojo::PendingRemote<network::mojom::URLLoaderFactory> target,
    std::string document_url,
    bool is_main_frame_navigation)
    : target_(std::move(target)),
      document_url_(std::move(document_url)),
      is_main_frame_navigation_(is_main_frame_navigation) {
  receivers_.Add(this, std::move(receiver));
  receivers_.set_disconnect_handler(base::BindRepeating(
      &OrbitContentBlockingURLLoaderFactory::OnDisconnect,
      base::Unretained(this)));
}

OrbitContentBlockingURLLoaderFactory::~OrbitContentBlockingURLLoaderFactory() =
    default;

void OrbitContentBlockingURLLoaderFactory::CreateLoaderAndStart(
    mojo::PendingReceiver<network::mojom::URLLoader> loader,
    int32_t request_id,
    uint32_t options,
    const network::ResourceRequest& url_request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const net::MutableNetworkTrafficAnnotationTag& traffic_annotation) {
  // Only what a page fetches is ever blocked, never the page the user asked
  // for -- no decision to make, so nothing to defer.
  if (is_main_frame_navigation_) {
    target_->CreateLoaderAndStart(std::move(loader), request_id, options,
                                  url_request, std::move(client),
                                  traffic_annotation);
    return;
  }

  // DecideContentBlocking is a real filter-list match over possibly thousands
  // of rules; runs off the UI thread so it doesn't block every pending task.
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::TaskPriority::USER_BLOCKING},
      base::BindOnce(&DecideContentBlocking, url_request.url.spec(),
                      document_url_,
                      static_cast<int>(ResourceTypeForRequest(url_request))),
      base::BindOnce(&OrbitContentBlockingURLLoaderFactory::OnDecision,
                      weak_factory_.GetWeakPtr(), std::move(loader),
                      request_id, options, url_request, std::move(client),
                      traffic_annotation));
}

void OrbitContentBlockingURLLoaderFactory::OnDecision(
    mojo::PendingReceiver<network::mojom::URLLoader> loader,
    int32_t request_id,
    uint32_t options,
    network::ResourceRequest url_request,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    net::MutableNetworkTrafficAnnotationTag traffic_annotation,
    ContentBlockingRequestDecision decision) {
  switch (decision.kind) {
    case ContentBlockingRequestDecision::Kind::kAllow:
      target_->CreateLoaderAndStart(std::move(loader), request_id, options,
                                    url_request, std::move(client),
                                    traffic_annotation);
      return;

    case ContentBlockingRequestDecision::Kind::kSubstitute:
      ServeSubstitution(url_request.url, std::move(loader), std::move(client),
                        decision.mime_type, decision.body);
      return;

    case ContentBlockingRequestDecision::Kind::kBlock:
      break;
  }

  mojo::Remote<network::mojom::URLLoaderClient> client_remote(std::move(client));
  client_remote->OnComplete(
      network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
}

void OrbitContentBlockingURLLoaderFactory::ServeSubstitution(
    const GURL& request_url,
    mojo::PendingReceiver<network::mojom::URLLoader> loader,
    mojo::PendingRemote<network::mojom::URLLoaderClient> client,
    const std::string& mime_type,
    const std::vector<uint8_t>& body) {
  mojo::Remote<network::mojom::URLLoaderClient> client_remote(std::move(client));

  mojo::ScopedDataPipeProducerHandle producer;
  mojo::ScopedDataPipeConsumerHandle consumer;
  if (!IsWellFormedMimeType(mime_type) ||
      body.size() > kMaxSubstitutionBodyBytes ||
      mojo::CreateDataPipe(
          base::checked_cast<uint32_t>(std::max<size_t>(body.size(), 1u)),
          producer, consumer) != MOJO_RESULT_OK ||
      producer->WriteAllData(base::span<const uint8_t>(body)) != MOJO_RESULT_OK) {
    client_remote->OnComplete(
        network::URLLoaderCompletionStatus(net::ERR_BLOCKED_BY_CLIENT));
    return;
  }
  // Closes the write end so the reader sees end-of-body; the whole stub is
  // already buffered, the pipe having been sized to hold exactly it.
  producer.reset();

  // nosniff pins the declared type; no-store avoids caching a stub from a
  // rule that's later disabled; ACAO:* lets a CORS-mode fetch see the stub.
  const std::string raw_headers = base::StringPrintf(
      "HTTP/1.1 200 OK\n"
      "Content-Type: %s\n"
      "Content-Length: %zu\n"
      "X-Content-Type-Options: nosniff\n"
      "Cache-Control: no-store\n"
      "Access-Control-Allow-Origin: *\n\n",
      mime_type.c_str(), body.size());

  auto head = network::mojom::URLResponseHead::New();
  head->headers = base::MakeRefCounted<net::HttpResponseHeaders>(
      net::HttpUtil::AssembleRawHeaders(raw_headers));
  head->mime_type = mime_type;
  head->content_length = static_cast<int64_t>(body.size());
  head->parsed_headers =
      network::PopulateParsedHeaders(head->headers.get(), request_url);
  const base::Time now = base::Time::Now();
  head->request_time = now;
  head->response_time = now;

  client_remote->OnReceiveResponse(std::move(head), std::move(consumer),
                                   std::nullopt);

  network::URLLoaderCompletionStatus status(net::OK);
  status.decoded_body_length = base::ByteSize(body.size());
  status.encoded_body_length = base::ByteSize(body.size());
  client_remote->OnComplete(status);

  StubURLLoader::Bind(std::move(loader));
}

void OrbitContentBlockingURLLoaderFactory::Clone(
    mojo::PendingReceiver<network::mojom::URLLoaderFactory> receiver) {
  receivers_.Add(this, std::move(receiver));
}

void OrbitContentBlockingURLLoaderFactory::OnDisconnect() {
  if (receivers_.empty()) {
    delete this;
  }
}

}  // namespace orbit
