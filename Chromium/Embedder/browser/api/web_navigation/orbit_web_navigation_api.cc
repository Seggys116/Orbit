// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_web_navigation_api.h"

#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_process_host.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_api_frame_id_map.h"
#include "extensions/common/api/extension_types.h"
#include "orbit/browser/orbit_frame_navigation_state.h"
#include "orbit/browser/orbit_tab_registry.h"

namespace orbit {

namespace {

using extensions::ExtensionApiFrameIdMap;
using extensions::api::extension_types::ToString;

base::DictValue BuildFrameResultDetails(content::RenderFrameHost* frame_host,
                                        OrbitFrameNavigationState* state) {
  base::DictValue details;
  details.Set("errorOccurred", state->GetErrorOccurredInFrame());
  details.Set("url", state->GetUrl().spec());
  details.Set("parentFrameId", ExtensionApiFrameIdMap::GetParentFrameId(frame_host));
  details.Set("documentId", ExtensionApiFrameIdMap::GetDocumentId(frame_host).ToString());
  if (content::RenderFrameHost* parent = frame_host->GetParentOrOuterDocument()) {
    details.Set("parentDocumentId",
               ExtensionApiFrameIdMap::GetDocumentId(parent).ToString());
  }
  details.Set("documentLifecycle",
             ToString(ExtensionApiFrameIdMap::GetDocumentLifecycle(frame_host)));
  details.Set("frameType", ToString(ExtensionApiFrameIdMap::GetFrameType(frame_host)));
  return details;
}

}  // namespace

ExtensionFunction::ResponseAction WebNavigationGetFrameFunction::Run() {
  const base::DictValue* params = args().empty() ? nullptr : args()[0].GetIfDict();
  if (!params) {
    return RespondNow(Error("webNavigation.getFrame requires a details object"));
  }

  content::RenderFrameHost* frame_host = nullptr;

  if (const std::string* document_id_string = params->FindString("documentId")) {
    ExtensionApiFrameIdMap::DocumentId document_id =
        ExtensionApiFrameIdMap::DocumentIdFromString(*document_id_string);
    if (!document_id) {
      return RespondNow(Error("Invalid documentId."));
    }
    frame_host =
        ExtensionApiFrameIdMap::Get()->GetRenderFrameHostByDocumentId(document_id);
    if (!frame_host) {
      return RespondNow(WithArguments(base::Value()));
    }
    content::WebContents* web_contents =
        content::WebContents::FromRenderFrameHost(frame_host);
    if (!web_contents || web_contents->GetBrowserContext() != browser_context()) {
      return RespondNow(WithArguments(base::Value()));
    }

    const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTabForWebContents(web_contents);
    const int32_t tab_id = tab ? tab->id : -1;
    const int frame_id = ExtensionApiFrameIdMap::GetFrameId(frame_host);
    if (std::optional<int> requested_tab_id = params->FindInt("tabId");
        requested_tab_id && *requested_tab_id != tab_id) {
      return RespondNow(WithArguments(base::Value()));
    }
    if (std::optional<int> requested_frame_id = params->FindInt("frameId");
        requested_frame_id && *requested_frame_id != frame_id) {
      return RespondNow(WithArguments(base::Value()));
    }
  } else {
    std::optional<int> tab_id = params->FindInt("tabId");
    std::optional<int> frame_id = params->FindInt("frameId");
    if (!tab_id || !frame_id) {
      return RespondNow(
          Error("Either documentId or both tabId and frameId must be specified."));
    }
    const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(*tab_id);
    if (!tab || !tab->web_contents) {
      return RespondNow(WithArguments(base::Value()));
    }
    frame_host = ExtensionApiFrameIdMap::GetRenderFrameHostById(tab->web_contents, *frame_id);
  }

  OrbitFrameNavigationState* state =
      frame_host ? OrbitFrameNavigationState::GetForCurrentDocument(frame_host) : nullptr;
  if (!state || !OrbitFrameNavigationState::IsValidUrl(state->GetUrl())) {
    return RespondNow(WithArguments(base::Value()));
  }

  return RespondNow(WithArguments(BuildFrameResultDetails(frame_host, state)));
}

ExtensionFunction::ResponseAction WebNavigationGetAllFramesFunction::Run() {
  const base::DictValue* params = args().empty() ? nullptr : args()[0].GetIfDict();
  std::optional<int> tab_id = params ? params->FindInt("tabId") : std::nullopt;
  if (!tab_id) {
    return RespondNow(Error("webNavigation.getAllFrames requires details.tabId"));
  }

  const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(*tab_id);
  if (!tab || !tab->web_contents) {
    return RespondNow(WithArguments(base::Value()));
  }
  content::WebContents* web_contents = tab->web_contents;

  base::ListValue result;
  web_contents->ForEachRenderFrameHost(
      [web_contents, &result](content::RenderFrameHost* frame_host) {
        if (content::WebContents::FromRenderFrameHost(frame_host) != web_contents) {
          return;
        }
        if (frame_host->IsInLifecycleState(
                content::RenderFrameHost::LifecycleState::kInBackForwardCache)) {
          return;
        }
        OrbitFrameNavigationState* state =
            OrbitFrameNavigationState::GetForCurrentDocument(frame_host);
        if (!state || !OrbitFrameNavigationState::IsValidUrl(state->GetUrl())) {
          return;
        }
        base::DictValue details = BuildFrameResultDetails(frame_host, state);
        details.Set("processId", frame_host->GetProcess()->GetDeprecatedID());
        details.Set("frameId", ExtensionApiFrameIdMap::GetFrameId(frame_host));
        result.Append(base::Value(std::move(details)));
      });

  return RespondNow(WithArguments(std::move(result)));
}

}  // namespace orbit
