// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_permission_controller_delegate.h"

#include <algorithm>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/memory/raw_ptr.h"
#include "base/json/json_writer.h"
#include "base/values.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "orbit/browser/orbit_web_contents_host.h"
#include "third_party/blink/public/common/permissions/permission_utils.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace orbit {

namespace {

content::PermissionResult MakeResult(blink::mojom::PermissionStatus status) {
  return content::PermissionResult(status);
}

// Heap-allocated; passed as the opaque context to RequestPermissionPrompt and deleted
// by HandlePermissionDecision when it fires. Mirrors JavaScriptEvaluationBox's lifetime.
struct PendingPermissionRequest {
  raw_ptr<OrbitPermissionStore> store;
  url::Origin origin;
  std::vector<std::optional<OrbitPermissionStore::Kind>> kinds;
  std::vector<size_t> pending_indices;
  std::vector<content::PermissionResult> results;
  base::OnceCallback<void(const std::vector<content::PermissionResult>&)> callback;
};

// decision mirrors Orbit/Engine/EngineTypes.swift's PermissionDecision:
// 0=deny 1=allow 2=allowAlways 3=denyAlways -- see
// OrbitPermissionDecisionCallback in orbit_bridge_api.h.
void HandlePermissionDecision(void* opaque, int decision) {
  std::unique_ptr<PendingPermissionRequest> state(
      static_cast<PendingPermissionRequest*>(opaque));

  const bool granted = decision == 1 || decision == 2;
  const bool persist = decision == 2 || decision == 3;
  const blink::mojom::PermissionStatus status =
      granted ? blink::mojom::PermissionStatus::GRANTED
              : blink::mojom::PermissionStatus::DENIED;

  std::set<OrbitPermissionStore::Kind> persisted_kinds;
  for (size_t index : state->pending_indices) {
    state->results[index] = MakeResult(status);
    if (persist && state->kinds[index] &&
        persisted_kinds.insert(*state->kinds[index]).second) {
      state->store->Set(*state->kinds[index], state->origin,
                        granted ? OrbitPermissionStore::Decision::kAllow
                                : OrbitPermissionStore::Decision::kBlock);
    }
  }
  std::move(state->callback).Run(state->results);
}

}  // namespace

OrbitPermissionControllerDelegate::OrbitPermissionControllerDelegate(
    PrefService* pref_service)
    : store_(pref_service) {}

OrbitPermissionControllerDelegate::~OrbitPermissionControllerDelegate() = default;

void OrbitPermissionControllerDelegate::RequestPermissionsFromCurrentDocument(
    content::RenderFrameHost* render_frame_host,
    const content::PermissionRequestDescription& request_description,
    base::OnceCallback<void(const std::vector<content::PermissionResult>&)> callback) {
  if (render_frame_host->IsNestedWithinFencedFrame()) {
    std::move(callback).Run(std::vector<content::PermissionResult>(
        request_description.permissions.size(),
        MakeResult(blink::mojom::PermissionStatus::DENIED)));
    return;
  }

  const GURL requesting_url = request_description.requesting_origin.is_valid()
      ? request_description.requesting_origin
      : render_frame_host->GetLastCommittedURL();
  const url::Origin origin = url::Origin::Create(requesting_url);

  const size_t count = request_description.permissions.size();
  std::vector<content::PermissionResult> results(
      count, MakeResult(blink::mojom::PermissionStatus::DENIED));
  std::vector<std::optional<OrbitPermissionStore::Kind>> kinds(count, std::nullopt);
  std::vector<size_t> pending_indices;
  std::vector<OrbitPermissionStore::Kind> pending_kinds;

  for (size_t i = 0; i < count; ++i) {
    std::optional<blink::PermissionType> type =
        blink::MaybePermissionDescriptorToPermissionType(request_description.permissions[i]);
    if (type == blink::PermissionType::CLIPBOARD_SANITIZED_WRITE) {
      // A transient-activation-gated write, never a persisted grant in any
      // shipping browser -- see OrbitPermissionStore::KindForPermissionType.
      results[i] = MakeResult(blink::mojom::PermissionStatus::GRANTED);
      continue;
    }
    std::optional<OrbitPermissionStore::Kind> kind =
        type ? OrbitPermissionStore::KindForPermissionType(*type) : std::nullopt;
    if (!kind) {
      continue;  // No Orbit UI surface for this type -- stays DENIED.
    }
    switch (store_.Get(*kind, origin)) {
      case OrbitPermissionStore::Decision::kAllow:
        results[i] = MakeResult(blink::mojom::PermissionStatus::GRANTED);
        break;
      case OrbitPermissionStore::Decision::kBlock:
        results[i] = MakeResult(blink::mojom::PermissionStatus::DENIED);
        break;
      case OrbitPermissionStore::Decision::kAsk:
        kinds[i] = kind;
        pending_indices.push_back(i);
        if (std::ranges::find(pending_kinds, *kind) == pending_kinds.end()) {
          pending_kinds.push_back(*kind);
        }
        break;
    }
  }

  if (pending_indices.empty()) {
    std::move(callback).Run(results);
    return;
  }

  content::WebContents* web_contents = content::WebContents::FromRenderFrameHost(render_frame_host);
  OrbitWebContentsHost* host =
      web_contents ? OrbitWebContentsHost::FromWebContents(web_contents) : nullptr;
  if (!host) {
    host = OrbitWebContentsHost::AnyLiveHost();
  }
  if (!host) {
    // No tab left to ask -- deny rather than default to granted.
    std::move(callback).Run(results);
    return;
  }

  base::ListValue kinds_json;
  for (OrbitPermissionStore::Kind kind : pending_kinds) {
    kinds_json.Append(std::string(OrbitPermissionStore::KindToString(kind)));
  }
  std::string kinds_json_string;
  base::JSONWriter::Write(kinds_json, &kinds_json_string);

  auto* state = new PendingPermissionRequest{
      &store_, origin, std::move(kinds), std::move(pending_indices),
      std::move(results), std::move(callback)};

  host->RequestPermissionPrompt(kinds_json_string, origin.Serialize(),
                                &HandlePermissionDecision, state);
}

content::PermissionStatus OrbitPermissionControllerDelegate::GetPermissionStatus(
    const blink::mojom::PermissionDescriptorPtr& permission,
    const GURL& requesting_origin,
    const GURL&) {
  std::optional<blink::PermissionType> type =
      blink::MaybePermissionDescriptorToPermissionType(permission);
  if (type == blink::PermissionType::CLIPBOARD_SANITIZED_WRITE) {
    return blink::mojom::PermissionStatus::GRANTED;
  }
  std::optional<OrbitPermissionStore::Kind> kind =
      type ? OrbitPermissionStore::KindForPermissionType(*type) : std::nullopt;
  if (!kind) {
    return blink::mojom::PermissionStatus::DENIED;
  }
  switch (store_.Get(*kind, url::Origin::Create(requesting_origin))) {
    case OrbitPermissionStore::Decision::kAllow:
      return blink::mojom::PermissionStatus::GRANTED;
    case OrbitPermissionStore::Decision::kBlock:
      return blink::mojom::PermissionStatus::DENIED;
    case OrbitPermissionStore::Decision::kAsk:
      return blink::mojom::PermissionStatus::ASK;
  }
  return blink::mojom::PermissionStatus::DENIED;
}

content::PermissionResult
OrbitPermissionControllerDelegate::GetPermissionResultForOriginWithoutContext(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    const url::Origin& requesting_origin,
    const url::Origin& embedding_origin) {
  return MakeResult(GetPermissionStatus(permission_descriptor, requesting_origin.GetURL(),
                                        embedding_origin.GetURL()));
}

content::PermissionResult
OrbitPermissionControllerDelegate::GetPermissionResultForCurrentDocument(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderFrameHost* render_frame_host,
    bool should_include_device_status) {
  if (render_frame_host->IsNestedWithinFencedFrame()) {
    return MakeResult(blink::mojom::PermissionStatus::DENIED);
  }
  return MakeResult(GetPermissionStatus(permission_descriptor,
                                        render_frame_host->GetLastCommittedURL(),
                                        render_frame_host->GetLastCommittedURL()));
}

content::PermissionResult OrbitPermissionControllerDelegate::GetPermissionResultForWorker(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderProcessHost*,
    const GURL& worker_origin) {
  return MakeResult(GetPermissionStatus(permission_descriptor, worker_origin, worker_origin));
}

content::PermissionResult
OrbitPermissionControllerDelegate::GetPermissionResultForEmbeddedRequester(
    const blink::mojom::PermissionDescriptorPtr& permission_descriptor,
    content::RenderFrameHost* render_frame_host,
    const url::Origin& overridden_origin) {
  if (render_frame_host->IsNestedWithinFencedFrame()) {
    return MakeResult(blink::mojom::PermissionStatus::DENIED);
  }
  return MakeResult(
      GetPermissionStatus(permission_descriptor, overridden_origin.GetURL(),
                          render_frame_host->GetLastCommittedURL()));
}

void OrbitPermissionControllerDelegate::ResetPermission(
    blink::PermissionType permission,
    const GURL& requesting_origin,
    const GURL&) {
  std::optional<OrbitPermissionStore::Kind> kind =
      OrbitPermissionStore::KindForPermissionType(permission);
  if (!kind) {
    return;
  }
  store_.Set(*kind, url::Origin::Create(requesting_origin), OrbitPermissionStore::Decision::kAsk);
}

}  // namespace orbit
