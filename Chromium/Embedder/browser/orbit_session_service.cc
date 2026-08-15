// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_session_service.h"

#include <memory>
#include <utility>

#include "base/values.h"
#include "content/public/browser/browser_context.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "orbit/bridge/orbit_bridge_internal.h"

namespace orbit {

namespace {

// `opaque` is the OnceCallback allocated for exactly one call, deleted here.
void RunPendingResultCallback(void* opaque, const char* result_json) {
  std::unique_ptr<OrbitSessionService::ResultCallback> callback(
      static_cast<OrbitSessionService::ResultCallback*>(opaque));
  if (!callback) {
    return;
  }
  std::move(*callback).Run(result_json ? std::string(result_json)
                                       : std::string());
}

}  // namespace

// static
OrbitSessionService& OrbitSessionService::GetInstance() {
  static base::NoDestructor<OrbitSessionService> instance;
  return *instance;
}

OrbitSessionService::OrbitSessionService() = default;
OrbitSessionService::~OrbitSessionService() = default;

void OrbitSessionService::SetDelegate(const OrbitSessionsDelegate& delegate) {
  delegate_ = delegate;
}

bool OrbitSessionService::GetRecentlyClosed(int32_t max_results,
                                            ResultCallback callback) {
  if (!delegate_.get_recently_closed) {
    return false;
  }
  auto pending = std::make_unique<ResultCallback>(std::move(callback));
  delegate_.get_recently_closed(delegate_.opaque, max_results,
                                &RunPendingResultCallback, pending.release());
  return true;
}

bool OrbitSessionService::Restore(const std::string& session_id,
                                  ResultCallback callback) {
  if (!delegate_.restore) {
    return false;
  }
  auto pending = std::make_unique<ResultCallback>(std::move(callback));
  delegate_.restore(delegate_.opaque, session_id.c_str(),
                    &RunPendingResultCallback, pending.release());
  return true;
}

void OrbitSessionService::NotifyChanged() {
  content::BrowserContext* browser_context = GetOrbitBrowserContext();
  if (!browser_context) {
    return;
  }
  extensions::EventRouter* router =
      extensions::EventRouter::Get(browser_context);
  if (!router) {
    return;
  }
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::SESSIONS_ON_CHANGED, "sessions.onChanged",
      base::ListValue(), browser_context));
}

}  // namespace orbit
