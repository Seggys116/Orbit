// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_sessions_api.h"

#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/values.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"
#include "extensions/common/permissions/permissions_data.h"
#include "orbit/browser/orbit_session_service.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "url/gurl.h"

namespace orbit {

namespace {

using extensions::mojom::APIPermissionID;

constexpr char kNoRecentlyClosedSessionsError[] =
    "There are no recently closed sessions.";
constexpr char kNoSessionListError[] =
    "Recently closed sessions are not available.";
constexpr char kMalformedSessionListError[] =
    "The recently closed session list could not be read.";

constexpr int kMaxSessionResults = 25;

// Duplicates OrbitTabRegistry::HasAccessToURL, which is private and takes a
// live OrbitTabInfo a closed tab has no equivalent of.
bool MayReportURL(const extensions::Extension* extension,
                  const std::string& url) {
  if (!extension) {
    return false;
  }
  if (extension->permissions_data()->HasAPIPermission(APIPermissionID::kTab)) {
    return true;
  }
  if (url.empty()) {
    return false;
  }
  return extension->permissions_data()->CanAccessPage(GURL(url), /*tab_id=*/-1,
                                                      /*error=*/nullptr);
}

// The bridge's Session carries a top-level "sessionId"; the JS-visible type
// does not, because upstream's does not.
void ScrubSession(base::DictValue& session,
                  const extensions::Extension* extension) {
  session.Remove("sessionId");
  base::DictValue* tab = session.FindDict("tab");
  if (!tab) {
    return;
  }
  const std::string* url = tab->FindString("url");
  if (MayReportURL(extension, url ? *url : std::string())) {
    return;
  }
  tab->Remove("url");
  tab->Remove("pendingUrl");
  tab->Remove("title");
  tab->Remove("favIconUrl");
}

// The restored tab is live again, so OrbitTabRegistry -- not Swift's snapshot
// of a closed record -- is what chrome.tabs itself would report for it.
void ReplaceRestoredTabWithLiveValue(base::DictValue& session,
                                     const extensions::Extension* extension) {
  const base::DictValue* tab = session.FindDict("tab");
  if (!tab) {
    return;
  }
  const std::optional<int> tab_id = tab->FindInt("id");
  if (!tab_id || *tab_id < 0) {
    return;
  }
  const OrbitTabRegistry& registry = OrbitTabRegistry::GetInstance();
  const OrbitTabInfo* info = registry.GetTab(*tab_id);
  if (!info) {
    return;
  }
  session.Set("tab", registry.CreateTabValue(*info, extension));
}

}  // namespace

ExtensionFunction::ResponseAction SessionsGetRecentlyClosedFunction::Run() {
  int max_results = kMaxSessionResults;
  if (!args().empty()) {
    if (const base::DictValue* filter = args()[0].GetIfDict()) {
      if (const std::optional<int> requested = filter->FindInt("maxResults")) {
        max_results = *requested;
      }
    } else {
      EXTENSION_FUNCTION_VALIDATE(args()[0].is_none());
    }
  }
  EXTENSION_FUNCTION_VALIDATE(max_results >= 0 &&
                              max_results <= kMaxSessionResults);

  if (!OrbitSessionService::GetInstance().GetRecentlyClosed(
          max_results,
          base::BindOnce(&SessionsGetRecentlyClosedFunction::OnRecentlyClosed,
                         this))) {
    return RespondNow(Error(kNoSessionListError));
  }
  // Swift answers this one synchronously; the ABI only promises "exactly once".
  return did_respond() ? AlreadyResponded() : RespondLater();
}

void SessionsGetRecentlyClosedFunction::OnRecentlyClosed(
    const std::string& json) {
  std::optional<base::ListValue> sessions =
      base::JSONReader::ReadList(json, base::JSON_PARSE_RFC);
  if (!sessions) {
    Respond(Error(kMalformedSessionListError));
    return;
  }
  for (base::Value& entry : *sessions) {
    if (base::DictValue* session = entry.GetIfDict()) {
      ScrubSession(*session, extension());
    }
  }
  Respond(WithArguments(std::move(*sessions)));
}

ExtensionFunction::ResponseAction SessionsRestoreFunction::Run() {
  std::string session_id;
  if (!args().empty()) {
    if (const std::string* requested = args()[0].GetIfString()) {
      session_id = *requested;
    } else {
      EXTENSION_FUNCTION_VALIDATE(args()[0].is_none());
    }
  }

  if (!OrbitSessionService::GetInstance().Restore(
          session_id,
          base::BindOnce(&SessionsRestoreFunction::OnRestored, this))) {
    return RespondNow(Error(kNoSessionListError));
  }
  return did_respond() ? AlreadyResponded() : RespondLater();
}

void SessionsRestoreFunction::OnRestored(const std::string& json) {
  std::optional<base::DictValue> session =
      base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!session) {
    Respond(Error(kMalformedSessionListError));
    return;
  }
  if (const std::string* error = session->FindString("error")) {
    Respond(Error(error->empty() ? kNoRecentlyClosedSessionsError : *error));
    return;
  }
  ReplaceRestoredTabWithLiveValue(*session, extension());
  ScrubSession(*session, extension());
  Respond(WithArguments(std::move(*session)));
}

}  // namespace orbit
