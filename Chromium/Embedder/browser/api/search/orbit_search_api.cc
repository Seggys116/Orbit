// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_search_api.h"

#include <optional>
#include <utility>

#include "base/functional/bind.h"
#include "base/values.h"
#include "orbit/browser/orbit_search_service.h"

namespace orbit {

namespace {

// Verbatim from search_api.cc, so an extension's error handling still matches.
constexpr char kEmptyTextError[] = "Empty text parameter.";
constexpr char kBothDispositionAndTabIdError[] =
    "Cannot set both 'disposition' and 'tabId'.";
constexpr char kNoActiveBrowserError[] = "No active browser.";

// search.json's Disposition, in the order the C ABI numbers it.
bool DispositionFromString(const std::string& name, int* disposition) {
  if (name == "CURRENT_TAB") {
    *disposition = 0;
  } else if (name == "NEW_TAB") {
    *disposition = 1;
  } else if (name == "NEW_WINDOW") {
    *disposition = 2;
  } else {
    return false;
  }
  return true;
}

}  // namespace

ExtensionFunction::ResponseAction SearchQueryFunction::Run() {
  const base::DictValue* query_info =
      args().empty() ? nullptr : args()[0].GetIfDict();
  EXTENSION_FUNCTION_VALIDATE(query_info);

  const std::string* text = query_info->FindString("text");
  EXTENSION_FUNCTION_VALIDATE(text);

  const std::optional<int> tab_id = query_info->FindInt("tabId");

  std::optional<int> disposition;
  if (const base::Value* raw = query_info->Find("disposition");
      raw && !raw->is_none()) {
    EXTENSION_FUNCTION_VALIDATE(raw->is_string());
    int parsed = 0;
    EXTENSION_FUNCTION_VALIDATE(DispositionFromString(raw->GetString(), &parsed));
    disposition = parsed;
  }

  if (text->empty()) {
    return RespondNow(Error(kEmptyTextError));
  }
  if (tab_id && disposition) {
    return RespondNow(Error(kBothDispositionAndTabIdError));
  }

  if (!OrbitSearchService::GetInstance().Query(
          *text, disposition.value_or(0), tab_id.has_value(),
          tab_id.value_or(0),
          base::BindOnce(&SearchQueryFunction::OnQueryComplete, this))) {
    return RespondNow(Error(kNoActiveBrowserError));
  }
  return did_respond() ? AlreadyResponded() : RespondLater();
}

void SearchQueryFunction::OnQueryComplete(const std::string& error) {
  Respond(error.empty() ? NoArguments() : Error(error));
}

}  // namespace orbit
