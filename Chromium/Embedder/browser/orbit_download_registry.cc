// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_download_registry.h"

#include <memory>
#include <optional>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/stringprintf.h"
#include "base/time/time.h"
#include "components/download/public/common/download_interrupt_reasons.h"
#include "components/download/public/common/download_item.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"

namespace orbit {

namespace {

OrbitDownloadsRequestCallback g_request_callback = nullptr;
void* g_request_opaque = nullptr;

constexpr char kDownloadsUnavailable[] = "Downloads are not available.";

constexpr char kOnCreatedEventName[] = "downloads.onCreated";
constexpr char kOnChangedEventName[] = "downloads.onChanged";
constexpr char kOnErasedEventName[] = "downloads.onErased";

// bytesReceived is excluded exactly as upstream excludes it.
constexpr const char* kDeltaFields[] = {
    "url",   "finalUrl", "filename", "danger",     "mime",   "startTime",
    "state", "endTime",  "error",    "canResume",  "paused", "exists",
    "totalBytes"};

struct ReplyState {
  bool received = false;
  std::string json;
};

void OnReply(void* reply_ctx, const char* json) {
  auto* state = static_cast<ReplyState*>(reply_ctx);
  state->received = true;
  state->json = json ? json : std::string();
}

std::string FormatIso8601(const base::Time& time) {
  base::Time::Exploded exploded;
  time.UTCExplode(&exploded);
  return base::StringPrintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
                            exploded.year, exploded.month,
                            exploded.day_of_month, exploded.hour,
                            exploded.minute, exploded.second,
                            exploded.millisecond);
}

std::string IsoFromUnixSeconds(double seconds) {
  return FormatIso8601(base::Time::FromSecondsSinceUnixEpoch(seconds));
}

std::string StateName(download::DownloadItem::DownloadState state) {
  switch (state) {
    case download::DownloadItem::IN_PROGRESS:
      return "in_progress";
    case download::DownloadItem::COMPLETE:
      return "complete";
    case download::DownloadItem::CANCELLED:
    case download::DownloadItem::INTERRUPTED:
      return "interrupted";
    case download::DownloadItem::MAX_DOWNLOAD_STATE:
      break;
  }
  return "interrupted";
}

std::string InterruptReasonName(download::DownloadInterruptReason reason) {
  // The one reason with no schema counterpart; upstream folds it in too.
  if (reason == download::DOWNLOAD_INTERRUPT_REASON_LOCAL_DOWNLOAD_BLOCKED) {
    return "FILE_BLOCKED";
  }
  return download::DownloadInterruptReasonToString(reason);
}

bool AppendDelta(const base::DictValue& previous,
                 const base::DictValue& current,
                 const char* field,
                 base::DictValue* delta) {
  const base::Value* before = previous.Find(field);
  const base::Value* after = current.Find(field);
  if (!before && !after) {
    return false;
  }
  if (before && after && *before == *after) {
    return false;
  }
  base::DictValue change;
  if (before) {
    change.Set("previous", before->Clone());
  }
  if (after) {
    change.Set("current", after->Clone());
  }
  delta->Set(field, std::move(change));
  return true;
}

}  // namespace

// static
OrbitDownloadRegistry& OrbitDownloadRegistry::GetInstance() {
  static base::NoDestructor<OrbitDownloadRegistry> instance;
  return *instance;
}

OrbitDownloadRegistry::OrbitDownloadRegistry() = default;
OrbitDownloadRegistry::~OrbitDownloadRegistry() = default;

void OrbitDownloadRegistry::SetRequestCallback(
    OrbitDownloadsRequestCallback callback, void* opaque) {
  g_request_callback = callback;
  g_request_opaque = opaque;
}

void OrbitDownloadRegistry::StartObserving(
    content::BrowserContext* browser_context) {
  browser_context_ = browser_context;
}

void OrbitDownloadRegistry::StopObserving() {
  browser_context_ = nullptr;
  snapshot_.clear();
  items_.clear();
  index_by_id_.clear();
  guid_by_id_.clear();
  waiters_.clear();
  emitted_once_ = false;
}

void OrbitDownloadRegistry::SetItems(const std::string& items_json) {
  snapshot_.clear();
  std::optional<base::Value> parsed =
      base::JSONReader::Read(items_json, base::JSON_PARSE_RFC);
  if (parsed && parsed->is_list()) {
    snapshot_ = std::move(*parsed).TakeList();
  }
  Refresh();
  emitted_once_ = true;
  RunPendingWaiters();
}

base::DictValue OrbitDownloadRegistry::BuildItem(
    const base::DictValue& snapshot_item) const {
  const std::string* guid = snapshot_item.FindString("guid");
  download::DownloadItem* live = nullptr;
  if (browser_context_ && guid && !guid->empty()) {
    if (content::DownloadManager* manager =
            browser_context_->GetDownloadManager()) {
      live = manager->GetDownloadByGuid(*guid);
    }
  }

  base::DictValue item;
  item.Set("id", snapshot_item.FindInt("id").value_or(0));

  const std::string* url = snapshot_item.FindString("url");
  const std::string* final_url = snapshot_item.FindString("finalUrl");
  item.Set("url", url ? *url : std::string());
  item.Set("finalUrl",
           final_url ? *final_url : (url ? *url : std::string()));

  std::string referrer;
  if (live && live->GetReferrerUrl().is_valid()) {
    referrer = live->GetReferrerUrl().spec();
  } else if (const std::string* stored = snapshot_item.FindString("referrer")) {
    referrer = *stored;
  }
  item.Set("referrer", referrer);

  const std::string* filename = snapshot_item.FindString("filename");
  item.Set("filename", filename ? *filename : std::string());
  item.Set("danger", "safe");

  const std::string* mime = snapshot_item.FindString("mime");
  item.Set("mime", mime ? *mime : std::string());

  item.Set("startTime",
           IsoFromUnixSeconds(snapshot_item.FindDouble("startTime").value_or(0)));
  if (std::optional<double> end_time = snapshot_item.FindDouble("endTime")) {
    item.Set("endTime", IsoFromUnixSeconds(*end_time));
  }

  const std::string* snapshot_state = snapshot_item.FindString("state");
  const bool exists = snapshot_item.FindBool("exists").value_or(false);

  if (live) {
    item.Set("state", StateName(live->GetState()));
    item.Set("paused", live->IsPaused());
    item.Set("canResume", live->CanResume());
    item.Set("bytesReceived", static_cast<double>(live->GetReceivedBytes()));
    const int64_t total = live->GetTotalBytes();
    item.Set("totalBytes", total > 0 ? static_cast<double>(total) : -1.0);
    download::DownloadInterruptReason reason = live->GetLastReason();
    if (reason == download::DOWNLOAD_INTERRUPT_REASON_NONE &&
        live->GetState() == download::DownloadItem::CANCELLED) {
      reason = download::DOWNLOAD_INTERRUPT_REASON_USER_CANCELED;
    }
    if (reason != download::DOWNLOAD_INTERRUPT_REASON_NONE) {
      item.Set("error", InterruptReasonName(reason));
    }
  } else {
    item.Set("state", snapshot_state ? *snapshot_state : std::string("complete"));
    item.Set("paused", snapshot_item.FindBool("paused").value_or(false));
    item.Set("canResume", false);
    item.Set("bytesReceived",
             snapshot_item.FindDouble("bytesReceived").value_or(0));
    const double total = snapshot_item.FindDouble("totalBytes").value_or(0);
    item.Set("totalBytes", total > 0 ? total : -1.0);
    if (const std::string* error = snapshot_item.FindString("error")) {
      item.Set("error", *error);
    }
  }

  item.Set("exists", exists);
  return item;
}

void OrbitDownloadRegistry::Refresh() {
  base::ListValue rebuilt;
  std::map<int, size_t> index;
  std::map<int, std::string> guids;
  for (const base::Value& entry : snapshot_) {
    const base::DictValue* snapshot_item = entry.GetIfDict();
    if (!snapshot_item) {
      continue;
    }
    std::optional<int> id = snapshot_item->FindInt("id");
    if (!id || index.contains(*id)) {
      continue;
    }
    const std::string* guid = snapshot_item->FindString("guid");
    guids[*id] = guid ? *guid : std::string();
    index[*id] = rebuilt.size();
    rebuilt.Append(BuildItem(*snapshot_item));
  }

  base::ListValue previous_items = std::move(items_);
  std::map<int, size_t> previous_index = std::move(index_by_id_);
  items_ = std::move(rebuilt);
  index_by_id_ = std::move(index);
  guid_by_id_ = std::move(guids);

  // Chrome fires nothing for downloads that already existed at startup.
  if (!emitted_once_) {
    return;
  }

  for (const auto& [id, position] : index_by_id_) {
    const base::DictValue& current = items_[position].GetDict();
    auto previous = previous_index.find(id);
    if (previous == previous_index.end()) {
      FireCreated(current);
      continue;
    }
    const base::DictValue& before = previous_items[previous->second].GetDict();
    base::DictValue delta;
    bool changed = false;
    for (const char* field : kDeltaFields) {
      changed |= AppendDelta(before, current, field, &delta);
    }
    if (changed) {
      delta.Set("id", id);
      FireChanged(std::move(delta));
    }
  }

  for (const auto& entry : previous_index) {
    if (!index_by_id_.contains(entry.first)) {
      FireErased(entry.first);
    }
  }
}

void OrbitDownloadRegistry::FireCreated(const base::DictValue& item) const {
  extensions::EventRouter* router =
      browser_context_ ? extensions::EventRouter::Get(browser_context_)
                       : nullptr;
  if (!router) {
    return;
  }
  base::ListValue args;
  args.Append(item.Clone());
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::DOWNLOADS_ON_CREATED, kOnCreatedEventName,
      std::move(args), browser_context_));
}

void OrbitDownloadRegistry::FireChanged(base::DictValue delta) const {
  extensions::EventRouter* router =
      browser_context_ ? extensions::EventRouter::Get(browser_context_)
                       : nullptr;
  if (!router) {
    return;
  }
  base::ListValue args;
  args.Append(std::move(delta));
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::DOWNLOADS_ON_CHANGED, kOnChangedEventName,
      std::move(args), browser_context_));
}

void OrbitDownloadRegistry::FireErased(int id) const {
  extensions::EventRouter* router =
      browser_context_ ? extensions::EventRouter::Get(browser_context_)
                       : nullptr;
  if (!router) {
    return;
  }
  base::ListValue args;
  args.Append(id);
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::DOWNLOADS_ON_ERASED, kOnErasedEventName,
      std::move(args), browser_context_));
}

const base::DictValue* OrbitDownloadRegistry::GetItem(int id) const {
  auto it = index_by_id_.find(id);
  if (it == index_by_id_.end()) {
    return nullptr;
  }
  return &items_[it->second].GetDict();
}

std::vector<const base::DictValue*> OrbitDownloadRegistry::AllItems() const {
  std::vector<const base::DictValue*> all;
  all.reserve(items_.size());
  for (const base::Value& entry : items_) {
    all.push_back(&entry.GetDict());
  }
  return all;
}

std::string OrbitDownloadRegistry::GuidForId(int id) const {
  auto it = guid_by_id_.find(id);
  return it == guid_by_id_.end() ? std::string() : it->second;
}

bool OrbitDownloadRegistry::Request(const std::string& method,
                                    base::DictValue args,
                                    std::string* error) {
  if (!g_request_callback) {
    *error = kDownloadsUnavailable;
    return false;
  }

  std::string args_json;
  base::JSONWriter::Write(args, &args_json);

  ReplyState reply;
  g_request_callback(g_request_opaque, method.c_str(), args_json.c_str(),
                     &OnReply, &reply);
  if (!reply.received) {
    *error = kDownloadsUnavailable;
    return false;
  }

  std::optional<base::DictValue> parsed =
      base::JSONReader::ReadDict(reply.json, base::JSON_PARSE_RFC);
  if (!parsed) {
    *error = kDownloadsUnavailable;
    return false;
  }
  if (const std::string* message = parsed->FindString("error")) {
    *error = *message;
    return false;
  }
  if (parsed->FindBool("ok").value_or(false)) {
    return true;
  }
  *error = kDownloadsUnavailable;
  return false;
}

int OrbitDownloadRegistry::IdForGuidInSnapshot(const std::string& guid) const {
  for (const auto& [id, item_guid] : guid_by_id_) {
    if (item_guid == guid) {
      return id;
    }
  }
  return -1;
}

void OrbitDownloadRegistry::ResolveIdForGuid(
    const std::string& guid, base::OnceCallback<void(int)> callback) {
  const int id = IdForGuidInSnapshot(guid);
  if (id >= 0) {
    std::move(callback).Run(id);
    return;
  }
  waiters_.emplace_back(guid, std::move(callback));
}

void OrbitDownloadRegistry::RunPendingWaiters() {
  if (waiters_.empty()) {
    return;
  }
  std::vector<std::pair<std::string, base::OnceCallback<void(int)>>> pending =
      std::move(waiters_);
  waiters_.clear();
  for (auto& [guid, callback] : pending) {
    const int id = IdForGuidInSnapshot(guid);
    if (id >= 0) {
      std::move(callback).Run(id);
    } else {
      waiters_.emplace_back(guid, std::move(callback));
    }
  }
}

}  // namespace orbit
