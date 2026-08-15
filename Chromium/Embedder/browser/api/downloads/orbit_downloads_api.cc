// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_downloads_api.h"

#include <algorithm>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <vector>

#include "base/base_paths.h"
#include "base/containers/span.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/path_service.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/values.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_source.h"
#include "components/download/public/common/download_url_parameters.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/render_frame_host.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"
#include "extensions/common/permissions/permissions_data.h"
#include "net/http/http_util.h"
#include "net/traffic_annotation/network_traffic_annotation.h"
#include "orbit/browser/orbit_download_bridge.h"
#include "orbit/browser/orbit_download_registry.h"
#include "services/network/public/cpp/resource_request_body.h"
#include "third_party/re2/src/re2/re2.h"
#include "url/gurl.h"

namespace orbit {

namespace {

constexpr char kFileAlreadyDeleted[] = "Download file already deleted";
constexpr char kFileNotRemoved[] = "Unable to remove file";
constexpr char kInvalidFilename[] = "Invalid filename";
constexpr char kInvalidFilter[] = "Invalid query filter";
constexpr char kInvalidHeaderName[] = "Invalid request header name";
constexpr char kInvalidHeaderUnsafe[] = "Unsafe request header name";
constexpr char kInvalidHeaderValue[] = "Invalid request header value";
constexpr char kInvalidId[] = "Invalid downloadId";
constexpr char kInvalidOrderBy[] = "Invalid orderBy field";
constexpr char kInvalidQueryLimit[] = "Invalid query limit";
constexpr char kInvalidState[] = "Invalid state";
constexpr char kInvalidURL[] = "Invalid URL";
constexpr char kNotComplete[] = "Download must be complete";
constexpr char kNotInProgress[] = "Download must be in progress";
constexpr char kNotResumable[] = "DownloadItem.canResume must be true";
constexpr char kOpenPermission[] =
    "The \"downloads.open\" permission is required";
constexpr char kUserGesture[] = "User gesture required";

constexpr char kDownloadsUnavailable[] = "Downloads are not available.";

constexpr char kDownloadsDirectoryName[] = "Downloads";

constexpr const char* kSortableFields[] = {
    "bytesReceived", "danger", "endTime",    "exists", "filename", "mime",
    "paused",        "startTime", "state",   "totalBytes", "url", "finalUrl"};

constexpr const char* kEqualityFields[] = {
    "id",        "url",       "finalUrl",      "filename",   "danger",
    "mime",      "state",     "paused",        "error",      "startTime",
    "endTime",   "exists",    "bytesReceived", "totalBytes"};

constexpr const char* kQueryTermFields[] = {"filename", "url", "finalUrl"};

OrbitDownloadRegistry& Registry() {
  return OrbitDownloadRegistry::GetInstance();
}

std::string StringField(const base::DictValue& item, const char* key) {
  const std::string* value = item.FindString(key);
  return value ? *value : std::string();
}

bool IsTracked(content::BrowserContext* browser_context,
               const std::string& guid) {
  if (!browser_context || guid.empty()) {
    return false;
  }
  content::DownloadManager* manager = browser_context->GetDownloadManager();
  return manager && manager->GetDownloadByGuid(guid) != nullptr;
}

bool IsSortableField(const std::string& field) {
  for (const char* known : kSortableFields) {
    if (field == known) {
      return true;
    }
  }
  return false;
}

bool IsKnownState(const std::string& state) {
  return state == "in_progress" || state == "interrupted" ||
         state == "complete";
}

bool ValuesEqual(const base::Value& left, const base::Value& right) {
  const bool left_number = left.is_int() || left.is_double();
  const bool right_number = right.is_int() || right.is_double();
  if (left_number && right_number) {
    return left.GetDouble() == right.GetDouble();
  }
  return left == right;
}

int CompareValues(const base::Value* left, const base::Value* right) {
  if (!left && !right) {
    return 0;
  }
  if (!left) {
    return -1;
  }
  if (!right) {
    return 1;
  }
  if ((left->is_int() || left->is_double()) &&
      (right->is_int() || right->is_double())) {
    const double lhs = left->GetDouble();
    const double rhs = right->GetDouble();
    return lhs < rhs ? -1 : (lhs > rhs ? 1 : 0);
  }
  if (left->is_bool() && right->is_bool()) {
    if (left->GetBool() == right->GetBool()) {
      return 0;
    }
    return left->GetBool() ? 1 : -1;
  }
  if (left->is_string() && right->is_string()) {
    const std::string& lhs = left->GetString();
    const std::string& rhs = right->GetString();
    return lhs < rhs ? -1 : (lhs > rhs ? 1 : 0);
  }
  return 0;
}

std::optional<base::Time> ParseIso8601(const std::string& text) {
  base::Time time;
  if (!base::Time::FromUTCString(text.c_str(), &time)) {
    return std::nullopt;
  }
  return time;
}

std::optional<base::Time> ItemTime(const base::DictValue& item,
                                   const char* key) {
  const std::string* text = item.FindString(key);
  return text ? ParseIso8601(*text) : std::nullopt;
}

struct CompiledQuery {
  std::vector<std::string> include_terms;
  std::vector<std::string> exclude_terms;
  std::optional<base::Time> started_before;
  std::optional<base::Time> started_after;
  std::optional<base::Time> ended_before;
  std::optional<base::Time> ended_after;
  std::optional<double> total_bytes_greater;
  std::optional<double> total_bytes_less;
  std::unique_ptr<RE2> filename_regex;
  std::unique_ptr<RE2> url_regex;
  std::unique_ptr<RE2> final_url_regex;
  std::vector<std::pair<std::string, bool>> order_by;
  size_t limit = 1000;
  base::DictValue equality;
};

bool CompileRegex(const base::DictValue& query,
                  const char* key,
                  std::unique_ptr<RE2>* out,
                  std::string* error) {
  const std::string* pattern = query.FindString(key);
  if (!pattern) {
    return true;
  }
  auto compiled = std::make_unique<RE2>(*pattern);
  if (!compiled->ok()) {
    *error = kInvalidFilter;
    return false;
  }
  *out = std::move(compiled);
  return true;
}

bool CompileTime(const base::DictValue& query,
                 const char* key,
                 std::optional<base::Time>* out,
                 std::string* error) {
  const std::string* text = query.FindString(key);
  if (!text) {
    return true;
  }
  std::optional<base::Time> parsed = ParseIso8601(*text);
  if (!parsed) {
    *error = kInvalidFilter;
    return false;
  }
  *out = *parsed;
  return true;
}

bool CompileQuery(const base::DictValue* query,
                  CompiledQuery* out,
                  std::string* error) {
  if (!query) {
    return true;
  }

  if (const base::ListValue* terms = query->FindList("query")) {
    for (const base::Value& entry : *terms) {
      const std::string* text = entry.GetIfString();
      if (!text || text->empty()) {
        continue;
      }
      if ((*text)[0] == '-') {
        if (text->size() > 1) {
          out->exclude_terms.push_back(base::ToLowerASCII(text->substr(1)));
        }
      } else {
        out->include_terms.push_back(base::ToLowerASCII(*text));
      }
    }
  }

  if (!CompileTime(*query, "startedBefore", &out->started_before, error) ||
      !CompileTime(*query, "startedAfter", &out->started_after, error) ||
      !CompileTime(*query, "endedBefore", &out->ended_before, error) ||
      !CompileTime(*query, "endedAfter", &out->ended_after, error)) {
    return false;
  }

  out->total_bytes_greater = query->FindDouble("totalBytesGreater");
  out->total_bytes_less = query->FindDouble("totalBytesLess");

  if (!CompileRegex(*query, "filenameRegex", &out->filename_regex, error) ||
      !CompileRegex(*query, "urlRegex", &out->url_regex, error) ||
      !CompileRegex(*query, "finalUrlRegex", &out->final_url_regex, error)) {
    return false;
  }

  if (std::optional<int> limit = query->FindInt("limit")) {
    if (*limit < 0) {
      *error = kInvalidQueryLimit;
      return false;
    }
    out->limit = *limit == 0 ? std::numeric_limits<size_t>::max()
                             : static_cast<size_t>(*limit);
  }

  if (const std::string* state = query->FindString("state")) {
    if (!IsKnownState(*state)) {
      *error = kInvalidState;
      return false;
    }
  }

  if (const base::ListValue* order_by = query->FindList("orderBy")) {
    for (const base::Value& entry : *order_by) {
      const std::string* text = entry.GetIfString();
      if (!text || text->empty()) {
        continue;
      }
      const bool descending = (*text)[0] == '-';
      std::string field = descending ? text->substr(1) : *text;
      if (!IsSortableField(field)) {
        *error = kInvalidOrderBy;
        return false;
      }
      out->order_by.emplace_back(std::move(field), descending);
    }
  }

  for (const char* field : kEqualityFields) {
    if (const base::Value* value = query->Find(field)) {
      out->equality.Set(field, value->Clone());
    }
  }
  return true;
}

bool MatchesTerms(const CompiledQuery& query, const base::DictValue& item) {
  if (query.include_terms.empty() && query.exclude_terms.empty()) {
    return true;
  }
  std::string haystack;
  for (const char* field : kQueryTermFields) {
    haystack += base::ToLowerASCII(StringField(item, field));
    haystack += '\n';
  }
  for (const std::string& term : query.include_terms) {
    if (haystack.find(term) == std::string::npos) {
      return false;
    }
  }
  for (const std::string& term : query.exclude_terms) {
    if (haystack.find(term) != std::string::npos) {
      return false;
    }
  }
  return true;
}

bool MatchesQuery(const CompiledQuery& query, const base::DictValue& item) {
  if (!MatchesTerms(query, item)) {
    return false;
  }

  for (const auto field : query.equality) {
    const base::Value* actual = item.Find(field.first);
    if (!actual || !ValuesEqual(*actual, field.second)) {
      return false;
    }
  }

  const std::optional<base::Time> start = ItemTime(item, "startTime");
  if (query.started_before && (!start || *start >= *query.started_before)) {
    return false;
  }
  if (query.started_after && (!start || *start <= *query.started_after)) {
    return false;
  }
  const std::optional<base::Time> end = ItemTime(item, "endTime");
  if (query.ended_before && (!end || *end >= *query.ended_before)) {
    return false;
  }
  if (query.ended_after && (!end || *end <= *query.ended_after)) {
    return false;
  }

  const double total = item.FindDouble("totalBytes").value_or(0);
  if (query.total_bytes_greater && !(total > *query.total_bytes_greater)) {
    return false;
  }
  if (query.total_bytes_less && !(total < *query.total_bytes_less)) {
    return false;
  }

  if (query.filename_regex &&
      !RE2::PartialMatch(StringField(item, "filename"),
                         *query.filename_regex)) {
    return false;
  }
  if (query.url_regex &&
      !RE2::PartialMatch(StringField(item, "url"), *query.url_regex)) {
    return false;
  }
  if (query.final_url_regex &&
      !RE2::PartialMatch(StringField(item, "finalUrl"),
                         *query.final_url_regex)) {
    return false;
  }
  return true;
}

bool RunQuery(const base::DictValue* query,
              std::vector<const base::DictValue*>* results,
              std::string* error) {
  CompiledQuery compiled;
  if (!CompileQuery(query, &compiled, error)) {
    return false;
  }

  for (const base::DictValue* item : Registry().AllItems()) {
    if (MatchesQuery(compiled, *item)) {
      results->push_back(item);
    }
  }

  if (!compiled.order_by.empty()) {
    std::stable_sort(
        results->begin(), results->end(),
        [&compiled](const base::DictValue* left, const base::DictValue* right) {
          for (const auto& [field, descending] : compiled.order_by) {
            const int comparison =
                CompareValues(left->Find(field), right->Find(field));
            if (comparison < 0) {
              return !descending;
            }
            if (comparison > 0) {
              return descending;
            }
          }
          // startTime is reported to the millisecond, so two downloads begun in
          // the same one tie; ids are allocated in creation order, so breaking
          // on id keeps that order and reverses with the primary field.
          const int left_id = left->FindInt("id").value_or(0);
          const int right_id = right->FindInt("id").value_or(0);
          return compiled.order_by.front().second ? left_id > right_id
                                                  : left_id < right_id;
        });
  }

  if (results->size() > compiled.limit) {
    results->resize(compiled.limit);
  }
  return true;
}

}  // namespace

ExtensionFunction::ResponseAction DownloadsDownloadFunction::Run() {
  const base::DictValue* options =
      args().empty() ? nullptr : args()[0].GetIfDict();
  EXTENSION_FUNCTION_VALIDATE(options);

  const std::string* url_string = options->FindString("url");
  EXTENSION_FUNCTION_VALIDATE(url_string);

  const GURL url(*url_string);
  if (!url.is_valid()) {
    return RespondNow(Error(kInvalidURL));
  }

  base::FilePath suggested_path;
  if (const std::string* filename = options->FindString("filename")) {
    // '%' is stripped first: it would otherwise expand as an env variable.
    std::string sanitized;
    base::ReplaceChars(*filename, "%", "_", &sanitized);
    suggested_path = base::FilePath::FromUTF8Unsafe(sanitized);
    if (suggested_path.empty() || suggested_path.IsAbsolute() ||
        suggested_path.ReferencesParent()) {
      return RespondNow(Error(kInvalidFilename));
    }
  }

  const std::string* conflict_action = options->FindString("conflictAction");
  base::FilePath forced_path;
  if (conflict_action && *conflict_action == "overwrite") {
    if (suggested_path.empty()) {
      return RespondNow(Error(kInvalidFilename));
    }
    base::FilePath home;
    if (!base::PathService::Get(base::DIR_HOME, &home)) {
      return RespondNow(Error(kDownloadsUnavailable));
    }
    // A forced path is what OrbitDownloadManagerDelegate takes verbatim.
    forced_path = home.Append(kDownloadsDirectoryName).Append(suggested_path);
  }

  content::DownloadManager* manager =
      browser_context() ? browser_context()->GetDownloadManager() : nullptr;
  if (!manager) {
    return RespondNow(Error(kDownloadsUnavailable));
  }

  net::NetworkTrafficAnnotationTag traffic_annotation =
      net::DefineNetworkTrafficAnnotation("orbit_downloads_api", R"(
        semantics {
          sender: "Downloads API"
          description:
            "This request is made when an extension makes an API call to "
            "download a file."
          trigger:
            "An API call from an extension, can be in response to user input "
            "or autonomously."
          data:
            "The extension may provide any data that it has permission to "
            "access, or is provided to it by the user."
          destination: OTHER
        }
        policy {
          cookies_allowed: YES
          cookies_store: "user"
          setting:
            "This feature cannot be disabled in settings, but disabling all "
            "extensions will prevent it."
          policy_exception_justification:
            "Orbit has no enterprise policy support."
        })");

  std::unique_ptr<download::DownloadUrlParameters> params;
  if (content::RenderFrameHost* frame = render_frame_host()) {
    params = frame->CreateDownloadUrlParameters(url, traffic_annotation);
  } else {
    params = std::make_unique<download::DownloadUrlParameters>(
        url, traffic_annotation);
    params->set_render_process_host_id(source_process_id());
    if (extension()) {
      params->set_initiator(extension()->origin());
    }
  }

  if (const base::ListValue* headers = options->FindList("headers")) {
    for (const base::Value& entry : *headers) {
      const base::DictValue* header = entry.GetIfDict();
      EXTENSION_FUNCTION_VALIDATE(header);
      const std::string* name = header->FindString("name");
      const std::string* value = header->FindString("value");
      EXTENSION_FUNCTION_VALIDATE(name && value);
      if (!net::HttpUtil::IsValidHeaderName(*name)) {
        return RespondNow(Error(kInvalidHeaderName));
      }
      if (!net::HttpUtil::IsSafeHeader(*name, *value)) {
        return RespondNow(Error(kInvalidHeaderUnsafe));
      }
      if (!net::HttpUtil::IsValidHeaderValue(*value)) {
        return RespondNow(Error(kInvalidHeaderValue));
      }
      params->add_request_header(*name, *value);
    }
  }

  if (const std::string* method = options->FindString("method")) {
    params->set_method(*method);
  }
  if (const std::string* body = options->FindString("body")) {
    params->set_post_body(
        network::ResourceRequestBody::CreateFromCopyOfBytes(
            base::as_byte_span(*body)));
  }
  if (!forced_path.empty()) {
    params->set_file_path(forced_path);
  } else if (!suggested_path.empty()) {
    params->set_suggested_name(suggested_path.AsUTF16Unsafe());
  }
  params->set_callback(
      base::BindOnce(&DownloadsDownloadFunction::OnStarted, this));
  params->set_do_not_prompt_for_login(true);
  params->set_download_source(download::DownloadSource::EXTENSION_API);

  manager->DownloadUrl(std::move(params), nullptr);
  return RespondLater();
}

void DownloadsDownloadFunction::OnStarted(
    download::DownloadItem* item,
    download::DownloadInterruptReason interrupt_reason) {
  if (!item ||
      interrupt_reason != download::DOWNLOAD_INTERRUPT_REASON_NONE) {
    Respond(Error(download::DownloadInterruptReasonToString(interrupt_reason)));
    return;
  }
  Registry().ResolveIdForGuid(
      item->GetGuid(),
      base::BindOnce(&DownloadsDownloadFunction::OnIdResolved, this));
}

void DownloadsDownloadFunction::OnIdResolved(int id) {
  Respond(WithArguments(id));
}

ExtensionFunction::ResponseAction DownloadsSearchFunction::Run() {
  const base::DictValue* query =
      args().empty() ? nullptr : args()[0].GetIfDict();
  EXTENSION_FUNCTION_VALIDATE(query);

  // Upstream's search is what triggers the file-existence check.
  Registry().Refresh();

  std::vector<const base::DictValue*> matches;
  std::string error;
  if (!RunQuery(query, &matches, &error)) {
    return RespondNow(Error(std::move(error)));
  }

  base::ListValue results;
  for (const base::DictValue* item : matches) {
    results.Append(item->Clone());
  }
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction DownloadsPauseFunction::Run() {
  const std::optional<int> id =
      args().empty() ? std::nullopt : args()[0].GetIfInt();
  EXTENSION_FUNCTION_VALIDATE(id);

  const base::DictValue* item = Registry().GetItem(*id);
  if (!item) {
    return RespondNow(Error(kInvalidId));
  }
  if (StringField(*item, "state") != "in_progress") {
    return RespondNow(Error(kNotInProgress));
  }
  const std::string guid = Registry().GuidForId(*id);
  if (!IsTracked(Registry().browser_context(), guid)) {
    return RespondNow(Error(kNotInProgress));
  }
  PauseDownload(Registry().browser_context(), guid);
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction DownloadsResumeFunction::Run() {
  const std::optional<int> id =
      args().empty() ? std::nullopt : args()[0].GetIfInt();
  EXTENSION_FUNCTION_VALIDATE(id);

  const base::DictValue* item = Registry().GetItem(*id);
  if (!item) {
    return RespondNow(Error(kInvalidId));
  }
  if (!item->FindBool("canResume").value_or(false)) {
    return RespondNow(Error(kNotResumable));
  }
  ResumeDownload(Registry().browser_context(), Registry().GuidForId(*id));
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction DownloadsCancelFunction::Run() {
  const std::optional<int> id =
      args().empty() ? std::nullopt : args()[0].GetIfInt();
  EXTENSION_FUNCTION_VALIDATE(id);

  if (!Registry().GetItem(*id)) {
    return RespondNow(Error(kInvalidId));
  }
  CancelDownload(Registry().browser_context(), Registry().GuidForId(*id));
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction DownloadsOpenFunction::Run() {
  const std::optional<int> id =
      args().empty() ? std::nullopt : args()[0].GetIfInt();
  EXTENSION_FUNCTION_VALIDATE(id);

  const base::DictValue* item = Registry().GetItem(*id);
  if (!item) {
    return RespondNow(Error(kInvalidId));
  }
  if (!extension() ||
      !extension()->permissions_data()->HasAPIPermission(
          extensions::mojom::APIPermissionID::kDownloadsOpen)) {
    return RespondNow(Error(kOpenPermission));
  }
  if (!user_gesture()) {
    return RespondNow(Error(kUserGesture));
  }
  if (StringField(*item, "state") != "complete") {
    return RespondNow(Error(kNotComplete));
  }

  base::DictValue request_args;
  request_args.Set("guid", Registry().GuidForId(*id));
  std::string error;
  if (!Registry().Request("open", std::move(request_args), &error)) {
    return RespondNow(Error(std::move(error)));
  }
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction DownloadsShowFunction::Run() {
  const std::optional<int> id =
      args().empty() ? std::nullopt : args()[0].GetIfInt();
  EXTENSION_FUNCTION_VALIDATE(id);

  if (!Registry().GetItem(*id)) {
    return RespondNow(Error(kInvalidId));
  }

  base::DictValue request_args;
  request_args.Set("guid", Registry().GuidForId(*id));
  std::string error;
  if (!Registry().Request("show", std::move(request_args), &error)) {
    return RespondNow(Error(std::move(error)));
  }
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction DownloadsShowDefaultFolderFunction::Run() {
  std::string error;
  if (!Registry().Request("showDefaultFolder", base::DictValue(), &error)) {
    return RespondNow(Error(std::move(error)));
  }
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction DownloadsEraseFunction::Run() {
  const base::DictValue* query =
      args().empty() ? nullptr : args()[0].GetIfDict();
  EXTENSION_FUNCTION_VALIDATE(query);

  std::vector<const base::DictValue*> matches;
  std::string error;
  if (!RunQuery(query, &matches, &error)) {
    return RespondNow(Error(std::move(error)));
  }

  // Read out first: the erase reply replaces everything `matches` points at.
  std::vector<int> erased_ids;
  base::ListValue guids;
  for (const base::DictValue* item : matches) {
    const int id = item->FindInt("id").value_or(0);
    erased_ids.push_back(id);
    guids.Append(Registry().GuidForId(id));
  }

  if (!erased_ids.empty()) {
    base::DictValue request_args;
    request_args.Set("guids", std::move(guids));
    if (!Registry().Request("erase", std::move(request_args), &error)) {
      return RespondNow(Error(std::move(error)));
    }
  }

  base::ListValue results;
  for (int id : erased_ids) {
    results.Append(id);
  }
  return RespondNow(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction DownloadsRemoveFileFunction::Run() {
  const std::optional<int> id =
      args().empty() ? std::nullopt : args()[0].GetIfInt();
  EXTENSION_FUNCTION_VALIDATE(id);

  const base::DictValue* item = Registry().GetItem(*id);
  if (!item) {
    return RespondNow(Error(kInvalidId));
  }
  if (StringField(*item, "state") != "complete") {
    return RespondNow(Error(kNotComplete));
  }
  if (!item->FindBool("exists").value_or(false)) {
    return RespondNow(Error(kFileAlreadyDeleted));
  }

  base::DictValue request_args;
  request_args.Set("guid", Registry().GuidForId(*id));
  std::string error;
  if (!Registry().Request("removeFile", std::move(request_args), &error)) {
    return RespondNow(Error(kFileNotRemoved));
  }
  return RespondNow(NoArguments());
}

}  // namespace orbit
