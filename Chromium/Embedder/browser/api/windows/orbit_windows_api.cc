// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_windows_api.h"

#include "base/strings/string_number_conversions.h"
#include "content/public/browser/web_contents.h"
#include "orbit/browser/orbit_tab_registry.h"

namespace orbit {

namespace {

constexpr int32_t kWindowIdCurrent = -2;

bool PopulateFrom(const base::ListValue& args, size_t arg_index) {
  if (args.size() <= arg_index) {
    return false;
  }
  const base::DictValue* query_options = args[arg_index].GetIfDict();
  if (!query_options) {
    return false;
  }
  return query_options->FindBool("populate").value_or(false);
}

int32_t CurrentWindowIdFor(ExtensionFunction* function) {
  if (content::WebContents* sender = function->GetSenderWebContents()) {
    if (const OrbitTabInfo* tab =
            OrbitTabRegistry::GetInstance().GetTabForWebContents(sender)) {
      return tab->window_id;
    }
  }
  return OrbitTabRegistry::GetInstance().GetLastFocusedWindowId();
}

}  // namespace

ExtensionFunction::ResponseAction WindowsGetFunction::Run() {
  if (args().empty() || !args()[0].is_int()) {
    return RespondNow(Error("windows.get requires a numeric windowId"));
  }
  int32_t window_id = args()[0].GetInt();
  if (window_id == kWindowIdCurrent) {
    window_id = CurrentWindowIdFor(this);
  }
  const OrbitWindowInfo* window = OrbitTabRegistry::GetInstance().GetWindow(window_id);
  if (!window) {
    return RespondNow(
        Error("No window with id: " + base::NumberToString(window_id)));
  }
  return RespondNow(WithArguments(OrbitTabRegistry::GetInstance().CreateWindowValue(
      *window, extension(), PopulateFrom(args(), 1))));
}

ExtensionFunction::ResponseAction WindowsGetCurrentFunction::Run() {
  const int32_t window_id = CurrentWindowIdFor(this);
  const OrbitWindowInfo* window = OrbitTabRegistry::GetInstance().GetWindow(window_id);
  if (!window) {
    return RespondNow(Error("No current Orbit window"));
  }
  return RespondNow(WithArguments(OrbitTabRegistry::GetInstance().CreateWindowValue(
      *window, extension(), PopulateFrom(args(), 0))));
}

ExtensionFunction::ResponseAction WindowsGetLastFocusedFunction::Run() {
  const int32_t window_id =
      OrbitTabRegistry::GetInstance().GetLastFocusedWindowId();
  const OrbitWindowInfo* window = OrbitTabRegistry::GetInstance().GetWindow(window_id);
  if (!window) {
    return RespondNow(Error("No Orbit window has been focused"));
  }
  return RespondNow(WithArguments(OrbitTabRegistry::GetInstance().CreateWindowValue(
      *window, extension(), PopulateFrom(args(), 0))));
}

ExtensionFunction::ResponseAction WindowsGetAllFunction::Run() {
  const bool populate = PopulateFrom(args(), 0);
  base::ListValue result;
  for (const OrbitWindowInfo* window : OrbitTabRegistry::GetInstance().GetAllWindows()) {
    result.Append(base::Value(
        OrbitTabRegistry::GetInstance().CreateWindowValue(*window, extension(), populate)));
  }
  return RespondNow(WithArguments(std::move(result)));
}

}  // namespace orbit
