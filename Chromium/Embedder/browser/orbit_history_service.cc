// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_history_service.h"

#include <memory>
#include <optional>
#include <utility>

#include "base/json/json_reader.h"
#include "base/values.h"
#include "content/public/browser/browser_context.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "orbit/bridge/orbit_bridge_internal.h"

namespace orbit {

namespace {

constexpr char kOnVisitedEvent[] = "history.onVisited";
constexpr char kOnVisitRemovedEvent[] = "history.onVisitRemoved";

void BroadcastHistoryEvent(extensions::events::HistogramValue histogram_value,
                           const std::string& event_name,
                           base::ListValue args) {
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
      histogram_value, event_name, std::move(args), browser_context));
}

}  // namespace

void CompleteHistoryResult(void* callback_opaque, const char* result_json) {
  OrbitHistoryService::GetInstance().Complete(
      callback_opaque, result_json ? std::string(result_json) : std::string());
}

// static
OrbitHistoryService& OrbitHistoryService::GetInstance() {
  static base::NoDestructor<OrbitHistoryService> instance;
  return *instance;
}

OrbitHistoryService::OrbitHistoryService() = default;
OrbitHistoryService::~OrbitHistoryService() = default;

void OrbitHistoryService::SetDelegate(const OrbitHistoryDelegate& delegate) {
  delegate_ = delegate;

  std::set<ResultCallback*> abandoned;
  abandoned.swap(pending_);
  for (ResultCallback* callback : abandoned) {
    std::unique_ptr<ResultCallback> owned(callback);
    std::move(*owned).Run(std::string());
  }
}

void* OrbitHistoryService::Retain(ResultCallback callback) {
  ResultCallback* owned = new ResultCallback(std::move(callback));
  pending_.insert(owned);
  return owned;
}

void OrbitHistoryService::Complete(void* token, const std::string& json) {
  auto* callback = static_cast<ResultCallback*>(token);
  auto it = pending_.find(callback);
  if (it == pending_.end()) {
    return;
  }
  pending_.erase(it);
  std::unique_ptr<ResultCallback> owned(callback);
  std::move(*owned).Run(json);
}

bool OrbitHistoryService::Search(const std::string& query_json,
                                 ResultCallback callback) {
  if (!delegate_.search) {
    return false;
  }
  delegate_.search(delegate_.opaque, query_json.c_str(), &CompleteHistoryResult,
                   Retain(std::move(callback)));
  return true;
}

bool OrbitHistoryService::GetVisits(const std::string& url,
                                    ResultCallback callback) {
  if (!delegate_.get_visits) {
    return false;
  }
  delegate_.get_visits(delegate_.opaque, url.c_str(), &CompleteHistoryResult,
                       Retain(std::move(callback)));
  return true;
}

bool OrbitHistoryService::AddUrl(const std::string& url,
                                 const std::string& title,
                                 ResultCallback callback) {
  if (!delegate_.add_url) {
    return false;
  }
  delegate_.add_url(delegate_.opaque, url.c_str(), title.c_str(),
                    &CompleteHistoryResult, Retain(std::move(callback)));
  return true;
}

bool OrbitHistoryService::DeleteUrl(const std::string& url,
                                    ResultCallback callback) {
  if (!delegate_.delete_url) {
    return false;
  }
  delegate_.delete_url(delegate_.opaque, url.c_str(), &CompleteHistoryResult,
                       Retain(std::move(callback)));
  return true;
}

bool OrbitHistoryService::DeleteRange(double start_ms,
                                      double end_ms,
                                      ResultCallback callback) {
  if (!delegate_.delete_range) {
    return false;
  }
  delegate_.delete_range(delegate_.opaque, start_ms, end_ms,
                         &CompleteHistoryResult, Retain(std::move(callback)));
  return true;
}

bool OrbitHistoryService::DeleteAll(ResultCallback callback) {
  if (!delegate_.delete_all) {
    return false;
  }
  delegate_.delete_all(delegate_.opaque, &CompleteHistoryResult,
                       Retain(std::move(callback)));
  return true;
}

void OrbitHistoryService::NotifyVisited(const std::string& history_item_json) {
  std::optional<base::DictValue> item =
      base::JSONReader::ReadDict(history_item_json, base::JSON_PARSE_RFC);
  if (!item) {
    return;
  }
  base::ListValue args;
  args.Append(std::move(*item));
  BroadcastHistoryEvent(extensions::events::HISTORY_ON_VISITED,
                        kOnVisitedEvent, std::move(args));
}

void OrbitHistoryService::NotifyVisitRemoved(bool all_history,
                                             const std::string& urls_json) {
  base::DictValue removed;
  removed.Set("allHistory", all_history);
  if (!all_history) {
    std::optional<base::ListValue> urls =
        base::JSONReader::ReadList(urls_json, base::JSON_PARSE_RFC);
    // An unparseable list would silently become "nothing was removed", which
    // is the opposite of what happened.
    if (!urls) {
      return;
    }
    if (urls->empty()) {
      return;
    }
    removed.Set("urls", std::move(*urls));
  }

  base::ListValue args;
  args.Append(std::move(removed));
  BroadcastHistoryEvent(extensions::events::HISTORY_ON_VISIT_REMOVED,
                        kOnVisitRemovedEvent, std::move(args));
}

}  // namespace orbit
