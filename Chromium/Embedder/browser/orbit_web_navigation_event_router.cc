// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_web_navigation_event_router.h"

#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include "base/time/time.h"
#include "base/values.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_api_frame_id_map.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "extensions/common/api/extension_types.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"
#include "extensions/common/mojom/context_type.mojom-shared.h"
#include "extensions/common/mojom/event_dispatcher.mojom.h"
#include "extensions/common/permissions/permissions_data.h"
#include "net/base/net_errors.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_frame_navigation_state.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "ui/base/page_transition_types.h"
#include "url/gurl.h"

namespace orbit {

namespace {

using extensions::mojom::APIPermissionID;

constexpr int32_t kTabIdNone = -1;

extensions::EventRouter* GetEventRouter() {
  content::BrowserContext* browser_context = GetOrbitBrowserContext();
  if (!browser_context) {
    return nullptr;
  }
  return extensions::EventRouter::Get(browser_context);
}

int32_t TabIdFor(content::WebContents* web_contents) {
  const OrbitTabInfo* tab =
      web_contents ? OrbitTabRegistry::GetInstance().GetTabForWebContents(web_contents)
                  : nullptr;
  return tab ? tab->id : kTabIdNone;
}

// Gated on the "webNavigation" permission alone (no per-tab host scrubbing, unlike
// chrome.tabs) -- defense in depth for a listener still registered after revocation.
bool WillDispatchIfWebNavigationPermitted(
    content::BrowserContext* browser_context,
    extensions::mojom::ContextType context_type,
    const extensions::Extension* extension,
    const base::DictValue* listener_filter,
    std::optional<base::ListValue>& event_args_out,
    extensions::mojom::EventFilteringInfoPtr& event_filtering_info_out,
    bool* dispatch_separate_event_out) {
  return extension &&
        extension->permissions_data()->HasAPIPermission(APIPermissionID::kWebNavigation);
}

void DispatchEvent(extensions::events::HistogramValue histogram_value,
                   std::string_view event_name,
                   base::DictValue details,
                   const GURL& filter_url) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  base::ListValue args;
  args.Append(base::Value(std::move(details)));
  auto event = std::make_unique<extensions::Event>(histogram_value, event_name,
                                                    std::move(args));
  auto filter_info = extensions::mojom::EventFilteringInfo::New();
  filter_info->url = filter_url;
  event->filter_info = std::move(filter_info);
  event->will_dispatch_callback =
      base::BindRepeating(&WillDispatchIfWebNavigationPermitted);
  router->BroadcastEvent(std::move(event));
}

// Shared by every dispatch that already has a committed RenderFrameHost
// (i.e. everything but onBeforeNavigate/onErrorOccurred-from-NavigationHandle,
// which use the NavigationHandle overloads of ExtensionApiFrameIdMap below).
void SetCommonFrameDetails(base::DictValue& details,
                           content::WebContents* web_contents,
                           content::RenderFrameHost* frame_host) {
  using extensions::api::extension_types::ToString;

  details.Set("tabId", TabIdFor(web_contents));
  details.Set("processId", frame_host->GetProcess()->GetDeprecatedID());
  details.Set("frameId", extensions::ExtensionApiFrameIdMap::GetFrameId(frame_host));
  details.Set("parentFrameId",
             extensions::ExtensionApiFrameIdMap::GetParentFrameId(frame_host));
  details.Set(
      "documentId",
      extensions::ExtensionApiFrameIdMap::GetDocumentId(frame_host).ToString());
  if (content::RenderFrameHost* parent = frame_host->GetParentOrOuterDocument()) {
    details.Set(
        "parentDocumentId",
        extensions::ExtensionApiFrameIdMap::GetDocumentId(parent).ToString());
  }
  details.Set("frameType",
             ToString(extensions::ExtensionApiFrameIdMap::GetFrameType(frame_host)));
  details.Set(
      "documentLifecycle",
      ToString(extensions::ExtensionApiFrameIdMap::GetDocumentLifecycle(frame_host)));
  details.Set("timeStamp", base::Time::Now().InMillisecondsFSinceUnixEpoch());
}

bool IsReferenceFragmentNavigation(content::RenderFrameHost* frame_host, const GURL& url) {
  OrbitFrameNavigationState* state =
      OrbitFrameNavigationState::GetForCurrentDocument(frame_host);
  GURL existing_url = state ? state->GetUrl() : GURL();
  if (existing_url == url) {
    return false;
  }
  return existing_url.EqualsIgnoringRef(url);
}

std::string TransitionTypeString(ui::PageTransition transition) {
  std::string result = ui::PageTransitionGetCoreTransitionString(transition);
  if (ui::PageTransitionCoreTypeIs(transition, ui::PAGE_TRANSITION_AUTO_TOPLEVEL)) {
    result = "start_page";
  }
  return result;
}

base::ListValue TransitionQualifiersFor(ui::PageTransition transition) {
  base::ListValue qualifiers;
  if (transition & ui::PAGE_TRANSITION_CLIENT_REDIRECT) {
    qualifiers.Append("client_redirect");
  }
  if (transition & ui::PAGE_TRANSITION_SERVER_REDIRECT) {
    qualifiers.Append("server_redirect");
  }
  if (transition & ui::PAGE_TRANSITION_FORWARD_BACK) {
    qualifiers.Append("forward_back");
  }
  if (transition & ui::PAGE_TRANSITION_FROM_ADDRESS_BAR) {
    qualifiers.Append("from_address_bar");
  }
  return qualifiers;
}

void DispatchOnDOMContentLoaded(content::WebContents* web_contents,
                                content::RenderFrameHost* frame_host,
                                const GURL& url) {
  base::DictValue details;
  details.Set("url", url.spec());
  SetCommonFrameDetails(details, web_contents, frame_host);
  DispatchEvent(extensions::events::WEB_NAVIGATION_ON_DOM_CONTENT_LOADED,
               "webNavigation.onDOMContentLoaded", std::move(details), url);
}

void DispatchOnCompleted(content::WebContents* web_contents,
                         content::RenderFrameHost* frame_host,
                         const GURL& url) {
  base::DictValue details;
  details.Set("url", url.spec());
  SetCommonFrameDetails(details, web_contents, frame_host);
  DispatchEvent(extensions::events::WEB_NAVIGATION_ON_COMPLETED,
               "webNavigation.onCompleted", std::move(details), url);
}

void DispatchOnErrorOccurred(content::WebContents* web_contents,
                             content::RenderFrameHost* frame_host,
                             const GURL& url,
                             int error_code) {
  base::DictValue details;
  details.Set("url", url.spec());
  details.Set("error", net::ErrorToString(error_code));
  SetCommonFrameDetails(details, web_contents, frame_host);
  DispatchEvent(extensions::events::WEB_NAVIGATION_ON_ERROR_OCCURRED,
               "webNavigation.onErrorOccurred", std::move(details), url);
}

// Aborts the in-flight load for `frame_host`'s current document, if any --
// shared by RenderFrameDeleted and the RenderFrameHostChanged subtree walk
// below. Mirrors WebNavigationTabObserver::RenderFrameDeleted.
void HandleFrameGoingAway(content::WebContents* web_contents,
                          content::RenderFrameHost* frame_host) {
  OrbitFrameNavigationState* state =
      OrbitFrameNavigationState::GetForCurrentDocument(frame_host);
  if (!state || !state->CanSendEvents() || state->GetDocumentLoadCompleted()) {
    return;
  }
  DispatchOnErrorOccurred(web_contents, frame_host, state->GetUrl(), net::ERR_ABORTED);
  state->SetErrorOccurredInFrame();
}

}  // namespace

// static
void OrbitWebNavigationEventRouter::DidStartNavigation(
    content::NavigationHandle* navigation_handle) {
  if (navigation_handle->IsSameDocument() ||
      !OrbitFrameNavigationState::IsValidUrl(navigation_handle->GetURL())) {
    return;
  }

  base::DictValue details;
  const GURL url = navigation_handle->GetURL();
  details.Set("tabId", TabIdFor(navigation_handle->GetWebContents()));
  details.Set("url", url.spec());
  details.Set("processId", -1);
  details.Set("frameId", extensions::ExtensionApiFrameIdMap::GetFrameId(navigation_handle));
  details.Set("parentFrameId",
             extensions::ExtensionApiFrameIdMap::GetParentFrameId(navigation_handle));
  if (content::RenderFrameHost* parent =
          navigation_handle->GetParentFrameOrOuterDocument()) {
    details.Set(
        "parentDocumentId",
        extensions::ExtensionApiFrameIdMap::GetDocumentId(parent).ToString());
  }
  details.Set(
      "frameType",
      extensions::api::extension_types::ToString(
          extensions::ExtensionApiFrameIdMap::GetFrameType(navigation_handle)));
  details.Set(
      "documentLifecycle",
      extensions::api::extension_types::ToString(
          extensions::ExtensionApiFrameIdMap::GetDocumentLifecycle(navigation_handle)));
  details.Set("timeStamp", base::Time::Now().InMillisecondsFSinceUnixEpoch());

  DispatchEvent(extensions::events::WEB_NAVIGATION_ON_BEFORE_NAVIGATE,
               "webNavigation.onBeforeNavigate", std::move(details), url);
}

// static
void OrbitWebNavigationEventRouter::DidFinishNavigation(
    content::NavigationHandle* navigation_handle) {
  // Only picked once the navigation has committed; the accessor CHECKs before
  // that, and a cancelled navigation never gets there.
  content::RenderFrameHost* frame_host =
      navigation_handle->HasCommitted() ? navigation_handle->GetRenderFrameHost()
                                        : nullptr;

  if (navigation_handle->HasCommitted() && !navigation_handle->IsErrorPage()) {
    const bool is_same_document = navigation_handle->IsSameDocument();
    const bool is_reference_fragment_navigation =
        is_same_document &&
        IsReferenceFragmentNavigation(frame_host, navigation_handle->GetURL());

    OrbitFrameNavigationState::GetOrCreateForCurrentDocument(frame_host)
        ->StartTrackingDocumentLoad(navigation_handle->GetURL(), is_same_document,
                                    navigation_handle->IsServedFromBackForwardCache(),
                                    /*is_error_page=*/false);

    extensions::events::HistogramValue histogram_value;
    std::string event_name;
    if (is_reference_fragment_navigation) {
      histogram_value = extensions::events::WEB_NAVIGATION_ON_REFERENCE_FRAGMENT_UPDATED;
      event_name = "webNavigation.onReferenceFragmentUpdated";
    } else if (is_same_document) {
      histogram_value = extensions::events::WEB_NAVIGATION_ON_HISTORY_STATE_UPDATED;
      event_name = "webNavigation.onHistoryStateUpdated";
    } else {
      histogram_value = extensions::events::WEB_NAVIGATION_ON_COMMITTED;
      event_name = "webNavigation.onCommitted";
    }

    const GURL url = navigation_handle->GetURL();
    ui::PageTransition transition = navigation_handle->GetPageTransition();
    if (navigation_handle->WasServerRedirect()) {
      transition = ui::PageTransitionFromInt(transition |
                                             ui::PAGE_TRANSITION_SERVER_REDIRECT);
    }

    base::DictValue details;
    details.Set("url", url.spec());
    SetCommonFrameDetails(details, navigation_handle->GetWebContents(), frame_host);
    details.Set("transitionType", TransitionTypeString(transition));
    details.Set("transitionQualifiers", TransitionQualifiersFor(transition));
    DispatchEvent(histogram_value, event_name, std::move(details), url);

    if (navigation_handle->IsServedFromBackForwardCache()) {
      DispatchOnCompleted(navigation_handle->GetWebContents(), frame_host, url);
    }
    return;
  }

  if (navigation_handle->HasCommitted()) {
    OrbitFrameNavigationState::GetOrCreateForCurrentDocument(frame_host)
        ->StartTrackingDocumentLoad(navigation_handle->GetURL(),
                                    navigation_handle->IsSameDocument(),
                                    /*is_from_back_forward_cache=*/false,
                                    /*is_error_page=*/true);
  }

  const net::Error error_code = navigation_handle->GetNetErrorCode() != net::OK
                                    ? navigation_handle->GetNetErrorCode()
                                    : net::ERR_ABORTED;
  base::DictValue details;
  const GURL url = navigation_handle->GetURL();
  details.Set("tabId", TabIdFor(navigation_handle->GetWebContents()));
  details.Set("url", url.spec());
  details.Set("processId", -1);
  details.Set("frameId", extensions::ExtensionApiFrameIdMap::GetFrameId(navigation_handle));
  details.Set("parentFrameId",
             extensions::ExtensionApiFrameIdMap::GetParentFrameId(navigation_handle));
  details.Set("error", net::ErrorToString(error_code));
  details.Set(
      "documentId",
      extensions::ExtensionApiFrameIdMap::GetDocumentId(navigation_handle).ToString());
  if (content::RenderFrameHost* parent =
          navigation_handle->GetParentFrameOrOuterDocument()) {
    details.Set(
        "parentDocumentId",
        extensions::ExtensionApiFrameIdMap::GetDocumentId(parent).ToString());
  }
  details.Set(
      "frameType",
      extensions::api::extension_types::ToString(
          extensions::ExtensionApiFrameIdMap::GetFrameType(navigation_handle)));
  details.Set(
      "documentLifecycle",
      extensions::api::extension_types::ToString(
          extensions::ExtensionApiFrameIdMap::GetDocumentLifecycle(navigation_handle)));
  details.Set("timeStamp", base::Time::Now().InMillisecondsFSinceUnixEpoch());
  DispatchEvent(extensions::events::WEB_NAVIGATION_ON_ERROR_OCCURRED,
               "webNavigation.onErrorOccurred", std::move(details), url);
}

// static
void OrbitWebNavigationEventRouter::DOMContentLoaded(
    content::WebContents* web_contents,
    content::RenderFrameHost* render_frame_host) {
  OrbitFrameNavigationState* state =
      OrbitFrameNavigationState::GetForCurrentDocument(render_frame_host);
  if (!state || !state->CanSendEvents()) {
    return;
  }
  state->SetParsingFinished();
  DispatchOnDOMContentLoaded(web_contents, render_frame_host, state->GetUrl());

  if (!state->GetDocumentLoadCompleted()) {
    return;
  }
  DispatchOnCompleted(web_contents, render_frame_host, state->GetUrl());
}

// static
void OrbitWebNavigationEventRouter::DidFinishLoad(
    content::WebContents* web_contents,
    content::RenderFrameHost* render_frame_host,
    const GURL& validated_url) {
  OrbitFrameNavigationState* state =
      OrbitFrameNavigationState::GetForCurrentDocument(render_frame_host);
  if (!state) {
    return;
  }
  state->SetDocumentLoadCompleted();
  if (!state->CanSendEvents() || state->GetUrl() != validated_url ||
      !state->GetParsingFinished()) {
    return;
  }
  DispatchOnCompleted(web_contents, render_frame_host, state->GetUrl());
}

// static
void OrbitWebNavigationEventRouter::DidFailLoad(
    content::WebContents* web_contents,
    content::RenderFrameHost* render_frame_host,
    const GURL& validated_url,
    int error_code) {
  OrbitFrameNavigationState* state =
      OrbitFrameNavigationState::GetForCurrentDocument(render_frame_host);
  if (!state) {
    return;
  }
  if (state->CanSendEvents()) {
    DispatchOnErrorOccurred(web_contents, render_frame_host, state->GetUrl(), error_code);
  }
  state->SetErrorOccurredInFrame();
}

// static
void OrbitWebNavigationEventRouter::RenderFrameDeleted(
    content::WebContents* web_contents,
    content::RenderFrameHost* render_frame_host) {
  HandleFrameGoingAway(web_contents, render_frame_host);
}

// static
void OrbitWebNavigationEventRouter::RenderFrameHostPendingDeletion(
    content::WebContents* web_contents,
    content::RenderFrameHost* old_host) {
  old_host->ForEachRenderFrameHost(
      [web_contents](content::RenderFrameHost* render_frame_host) {
        if (OrbitFrameNavigationState::GetForCurrentDocument(render_frame_host)) {
          HandleFrameGoingAway(web_contents, render_frame_host);
          OrbitFrameNavigationState::DeleteForCurrentDocument(render_frame_host);
        }
      });
}

}  // namespace orbit
