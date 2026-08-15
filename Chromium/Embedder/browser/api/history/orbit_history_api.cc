// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_history_api.h"

#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/time/time.h"
#include "base/values.h"
#include "orbit/browser/orbit_history_service.h"
#include "url/gurl.h"

namespace orbit {

namespace {

constexpr char kInvalidUrlError[] = "Url is invalid.";
constexpr char kHistoryUnavailableError[] = "History is not available.";
constexpr char kHistoryFailedError[] = "The history operation failed.";

// chrome.history.search's own defaults: the last 24 hours, 100 results.
constexpr int kDefaultMaxResults = 100;
constexpr int kDefaultRecentDays = 1;

bool ValidateUrl(const std::string& url_string, GURL* url, std::string* error) {
  *url = GURL(url_string);
  if (!url->is_valid()) {
    *error = kInvalidUrlError;
    return false;
  }
  return true;
}

const base::DictValue* DetailsFrom(const base::ListValue& args) {
  return args.empty() ? nullptr : args[0].GetIfDict();
}

std::optional<double> FindNumber(const base::DictValue& dict, const char* key) {
  const base::Value* value = dict.Find(key);
  if (!value) {
    return std::nullopt;
  }
  if (value->is_double()) {
    return value->GetDouble();
  }
  if (value->is_int()) {
    return static_cast<double>(value->GetInt());
  }
  return std::nullopt;
}

// Anything that is not {"ok":true} is a failure, never a silent success.
bool MutationSucceeded(const std::string& json, std::string* error) {
  std::optional<base::DictValue> parsed =
      base::JSONReader::ReadDict(json, base::JSON_PARSE_RFC);
  if (!parsed) {
    *error = kHistoryFailedError;
    return false;
  }
  if (const std::string* message = parsed->FindString("error")) {
    *error = message->empty() ? kHistoryFailedError : *message;
    return false;
  }
  if (parsed->FindBool("ok").value_or(false)) {
    return true;
  }
  *error = kHistoryFailedError;
  return false;
}

}  // namespace

ExtensionFunction::ResponseAction HistorySearchFunction::Run() {
  const base::DictValue* query = DetailsFrom(args());
  EXTENSION_FUNCTION_VALIDATE(query);

  const std::string* text = query->FindString("text");
  const std::optional<double> start_time = FindNumber(*query, "startTime");
  const std::optional<double> end_time = FindNumber(*query, "endTime");
  const std::optional<double> max_results = FindNumber(*query, "maxResults");

  base::DictValue request;
  request.Set("text", text ? *text : std::string());
  request.Set("startTime",
              start_time.value_or((base::Time::Now() -
                                   base::Days(kDefaultRecentDays))
                                      .InMillisecondsFSinceUnixEpoch()));
  if (end_time) {
    request.Set("endTime", *end_time);
  } else {
    request.Set("endTime", base::Value());
  }
  request.Set("maxResults",
              max_results.value_or(static_cast<double>(kDefaultMaxResults)));

  std::string request_json;
  if (!base::JSONWriter::Write(request, &request_json)) {
    return RespondNow(Error(kHistoryFailedError));
  }

  if (!OrbitHistoryService::GetInstance().Search(
          request_json,
          base::BindOnce(&HistorySearchFunction::OnSearchComplete, this))) {
    return RespondNow(Error(kHistoryUnavailableError));
  }
  return RespondLater();
}

void HistorySearchFunction::OnSearchComplete(const std::string& json) {
  std::optional<base::ListValue> results =
      base::JSONReader::ReadList(json, base::JSON_PARSE_RFC);
  if (!results) {
    Respond(Error(kHistoryFailedError));
    return;
  }
  Respond(WithArguments(std::move(*results)));
}

ExtensionFunction::ResponseAction HistoryGetVisitsFunction::Run() {
  const base::DictValue* details = DetailsFrom(args());
  EXTENSION_FUNCTION_VALIDATE(details);
  const std::string* url_string = details->FindString("url");
  EXTENSION_FUNCTION_VALIDATE(url_string);

  GURL url;
  std::string error;
  if (!ValidateUrl(*url_string, &url, &error)) {
    return RespondNow(Error(std::move(error)));
  }

  if (!OrbitHistoryService::GetInstance().GetVisits(
          url.spec(),
          base::BindOnce(&HistoryGetVisitsFunction::OnGetVisitsComplete,
                         this))) {
    return RespondNow(Error(kHistoryUnavailableError));
  }
  return RespondLater();
}

void HistoryGetVisitsFunction::OnGetVisitsComplete(const std::string& json) {
  std::optional<base::ListValue> results =
      base::JSONReader::ReadList(json, base::JSON_PARSE_RFC);
  if (!results) {
    Respond(Error(kHistoryFailedError));
    return;
  }
  Respond(WithArguments(std::move(*results)));
}

ExtensionFunction::ResponseAction HistoryAddUrlFunction::Run() {
  const base::DictValue* details = DetailsFrom(args());
  EXTENSION_FUNCTION_VALIDATE(details);
  const std::string* url_string = details->FindString("url");
  EXTENSION_FUNCTION_VALIDATE(url_string);

  GURL url;
  std::string error;
  if (!ValidateUrl(*url_string, &url, &error)) {
    return RespondNow(Error(std::move(error)));
  }

  // addUrl carries no title, exactly as upstream's AddPage() does not.
  if (!OrbitHistoryService::GetInstance().AddUrl(
          url.spec(), std::string(),
          base::BindOnce(&HistoryAddUrlFunction::OnAddUrlComplete, this))) {
    return RespondNow(Error(kHistoryUnavailableError));
  }
  return RespondLater();
}

void HistoryAddUrlFunction::OnAddUrlComplete(const std::string& json) {
  std::string error;
  Respond(MutationSucceeded(json, &error) ? NoArguments()
                                          : Error(std::move(error)));
}

ExtensionFunction::ResponseAction HistoryDeleteUrlFunction::Run() {
  const base::DictValue* details = DetailsFrom(args());
  EXTENSION_FUNCTION_VALIDATE(details);
  const std::string* url_string = details->FindString("url");
  EXTENSION_FUNCTION_VALIDATE(url_string);

  GURL url;
  std::string error;
  if (!ValidateUrl(*url_string, &url, &error)) {
    return RespondNow(Error(std::move(error)));
  }

  if (!OrbitHistoryService::GetInstance().DeleteUrl(
          url.spec(),
          base::BindOnce(&HistoryDeleteUrlFunction::OnDeleteUrlComplete,
                         this))) {
    return RespondNow(Error(kHistoryUnavailableError));
  }
  return RespondLater();
}

void HistoryDeleteUrlFunction::OnDeleteUrlComplete(const std::string& json) {
  std::string error;
  Respond(MutationSucceeded(json, &error) ? NoArguments()
                                          : Error(std::move(error)));
}

ExtensionFunction::ResponseAction HistoryDeleteRangeFunction::Run() {
  const base::DictValue* range = DetailsFrom(args());
  EXTENSION_FUNCTION_VALIDATE(range);
  const std::optional<double> start_time = FindNumber(*range, "startTime");
  const std::optional<double> end_time = FindNumber(*range, "endTime");
  EXTENSION_FUNCTION_VALIDATE(start_time && end_time);

  if (!OrbitHistoryService::GetInstance().DeleteRange(
          *start_time, *end_time,
          base::BindOnce(&HistoryDeleteRangeFunction::OnDeleteRangeComplete,
                         this))) {
    return RespondNow(Error(kHistoryUnavailableError));
  }
  return RespondLater();
}

void HistoryDeleteRangeFunction::OnDeleteRangeComplete(
    const std::string& json) {
  std::string error;
  Respond(MutationSucceeded(json, &error) ? NoArguments()
                                          : Error(std::move(error)));
}

ExtensionFunction::ResponseAction HistoryDeleteAllFunction::Run() {
  if (!OrbitHistoryService::GetInstance().DeleteAll(
          base::BindOnce(&HistoryDeleteAllFunction::OnDeleteAllComplete,
                         this))) {
    return RespondNow(Error(kHistoryUnavailableError));
  }
  return RespondLater();
}

void HistoryDeleteAllFunction::OnDeleteAllComplete(const std::string& json) {
  std::string error;
  Respond(MutationSucceeded(json, &error) ? NoArguments()
                                          : Error(std::move(error)));
}

}  // namespace orbit
