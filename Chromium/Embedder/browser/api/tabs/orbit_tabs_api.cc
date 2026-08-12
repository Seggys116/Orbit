// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_tabs_api.h"

#include "base/memory/raw_ptr.h"

#include "base/strings/pattern.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/web_contents.h"
#include "extensions/common/extension.h"
#include "extensions/common/url_pattern.h"
#include "extensions/common/url_pattern_set.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "url/gurl.h"

namespace orbit {

namespace {

constexpr int32_t kWindowIdNone = -1;
constexpr int32_t kWindowIdCurrent = -2;

// The calling script's own tab's window, or the last-focused Orbit window if
// not called from a tab. Mirrors WINDOW_ID_CURRENT; see GetLastFocusedWindowId for why not the *currently* focused window.
int32_t CurrentWindowIdFor(ExtensionFunction* function) {
  if (content::WebContents* sender = function->GetSenderWebContents()) {
    if (const OrbitTabInfo* tab =
            OrbitTabRegistry::GetInstance().GetTabForWebContents(sender)) {
      return tab->window_id;
    }
  }
  return OrbitTabRegistry::GetInstance().GetLastFocusedWindowId();
}

// Only WINDOW_ID_CURRENT resolves to a window; WINDOW_ID_NONE must not be
// conflated with it, matching upstream GetBrowserFromWindowID.
int32_t ResolveWindowId(ExtensionFunction* function, int32_t requested) {
  if (requested == kWindowIdCurrent) {
    return CurrentWindowIdFor(function);
  }
  return requested;
}

// Mirrors tabs_api.cc's own MatchesBool: an absent filter matches everything,
// and an explicit `false` is a filter, not a no-op.
bool MatchesBool(const std::optional<bool>& expected, bool value) {
  return !expected || *expected == value;
}

// Omitted optional args arrive as a NONE placeholder (ArgumentParser::AddNull()),
// not a missing element, so matching by type (not index) reads every reload() call shape.
struct OptionalTabIdAndDict {
  std::optional<int32_t> tab_id;
  raw_ptr<const base::DictValue> properties = nullptr;
};

OptionalTabIdAndDict SplitOptionalTabIdAndDict(const base::ListValue& args) {
  OptionalTabIdAndDict split;
  for (const base::Value& arg : args) {
    if (arg.is_int() && !split.tab_id.has_value()) {
      split.tab_id = arg.GetInt();
    } else if (const base::DictValue* dict = arg.GetIfDict()) {
      split.properties = dict;
    }
  }
  return split;
}

const OrbitTabInfo* ActiveTabInWindow(int32_t window_id) {
  for (const OrbitTabInfo* tab : OrbitTabRegistry::GetInstance().GetAllTabs()) {
    if (tab->window_id == window_id && tab->active) {
      return tab;
    }
  }
  return nullptr;
}

}  // namespace

ExtensionFunction::ResponseAction TabsGetFunction::Run() {
  if (args().empty() || !args()[0].is_int()) {
    return RespondNow(Error("tabs.get requires a numeric tabId"));
  }
  const int32_t tab_id = args()[0].GetInt();
  const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(tab_id);
  if (!tab) {
    return RespondNow(
        Error("No tab with id: " + base::NumberToString(tab_id)));
  }
  return RespondNow(WithArguments(
      OrbitTabRegistry::GetInstance().CreateTabValue(*tab, extension())));
}

ExtensionFunction::ResponseAction TabsGetCurrentFunction::Run() {
  content::WebContents* sender = GetSenderWebContents();
  const OrbitTabInfo* tab =
      sender ? OrbitTabRegistry::GetInstance().GetTabForWebContents(sender)
             : nullptr;
  if (!tab) {
    // Matches chrome.tabs.getCurrent's own contract: undefined, not an
    // error, when called from a non-tab context.
    return RespondNow(NoArguments());
  }
  return RespondNow(WithArguments(
      OrbitTabRegistry::GetInstance().CreateTabValue(*tab, extension())));
}

ExtensionFunction::ResponseAction TabsQueryFunction::Run() {
  const base::DictValue* query_info =
      args().empty() ? nullptr : args()[0].GetIfDict();

  std::optional<bool> active;
  std::optional<bool> pinned;
  std::optional<bool> highlighted;
  std::optional<bool> audible;
  std::optional<bool> muted;
  std::optional<bool> discarded;
  std::optional<bool> auto_discardable;
  std::optional<bool> frozen;
  std::optional<bool> current_window;
  std::optional<bool> last_focused_window;
  std::optional<std::string> status;
  std::optional<std::string> title;
  std::optional<std::string> window_type;
  std::optional<int> index;
  std::optional<int> group_id;
  extensions::URLPatternSet url_patterns;
  int32_t window_id = kWindowIdNone;

  if (query_info) {
    active = query_info->FindBool("active");
    pinned = query_info->FindBool("pinned");
    highlighted = query_info->FindBool("highlighted");
    audible = query_info->FindBool("audible");
    muted = query_info->FindBool("muted");
    discarded = query_info->FindBool("discarded");
    auto_discardable = query_info->FindBool("autoDiscardable");
    frozen = query_info->FindBool("frozen");
    current_window = query_info->FindBool("currentWindow");
    last_focused_window = query_info->FindBool("lastFocusedWindow");
    index = query_info->FindInt("index");
    group_id = query_info->FindInt("groupId");
    if (const std::string* s = query_info->FindString("status")) {
      status = *s;
    }
    if (const std::string* s = query_info->FindString("title")) {
      title = *s;
    }
    if (const std::string* s = query_info->FindString("windowType")) {
      window_type = *s;
    }
    if (std::optional<int> requested = query_info->FindInt("windowId")) {
      window_id = ResolveWindowId(this, *requested);
    }

    // A match pattern or list of them, never exact string compare. SCHEME_ALL
    // is safe: matching alone grants no access -- the permission gate below still applies.
    const base::Value* url_value = query_info->Find("url");
    if (url_value) {
      std::vector<std::string> pattern_strings;
      if (const std::string* single = url_value->GetIfString()) {
        pattern_strings.push_back(*single);
      } else if (const base::ListValue* list = url_value->GetIfList()) {
        for (const base::Value& entry : *list) {
          if (const std::string* entry_string = entry.GetIfString()) {
            pattern_strings.push_back(*entry_string);
          }
        }
      }
      std::string error;
      if (!url_patterns.Populate(pattern_strings, URLPattern::SCHEME_ALL,
                                 /*allow_file_access=*/true, &error)) {
        return RespondNow(Error(std::move(error)));
      }
    }
  }

  const int32_t current_window_id = CurrentWindowIdFor(this);
  const int32_t last_focused_window_id =
      OrbitTabRegistry::GetInstance().GetLastFocusedWindowId();

  base::ListValue result;
  for (const OrbitTabInfo* tab : OrbitTabRegistry::GetInstance().GetAllTabs()) {
    if (window_id >= 0 && tab->window_id != window_id) {
      continue;
    }
    if (!MatchesBool(current_window, tab->window_id == current_window_id)) {
      continue;
    }
    if (!MatchesBool(last_focused_window,
                     tab->window_id == last_focused_window_id)) {
      continue;
    }
    // Every Orbit window is a normal browser window; there are no popup,
    // panel, app or devtools windows for a query to name.
    if (window_type && *window_type != "normal") {
      continue;
    }
    if (index && tab->index != *index) {
      continue;
    }
    if (!MatchesBool(active, tab->active)) {
      continue;
    }
    if (!MatchesBool(pinned, tab->pinned)) {
      continue;
    }
    if (!MatchesBool(highlighted, tab->active)) {
      continue;
    }
    // Orbit has no tab groups, so every tab is TAB_GROUP_ID_NONE.
    if (group_id && *group_id != -1) {
      continue;
    }
    content::WebContents* contents = tab->web_contents;
    if (!MatchesBool(audible, contents && contents->IsCurrentlyAudible())) {
      continue;
    }
    if (!MatchesBool(muted, contents && contents->IsAudioMuted())) {
      continue;
    }
    if (!MatchesBool(discarded, contents && contents->WasDiscarded())) {
      continue;
    }
    if (!MatchesBool(auto_discardable, true)) {
      continue;
    }
    if (!MatchesBool(frozen, false)) {
      continue;
    }
    if (status) {
      const bool loading = contents && contents->IsLoading();
      const std::string tab_status = loading ? "loading" : "complete";
      if (tab_status != *status) {
        continue;
      }
    }

    const bool check_title = title && !title->empty();
    if (check_title || !url_patterns.is_empty()) {
      // Only matches a tab this extension can already see the url of --
      // otherwise these filters could be used as an oracle to learn it a bit at a time.
      if (!OrbitTabRegistry::GetInstance().HasTabsAccess(extension(), *tab)) {
        continue;
      }
      const std::u16string tab_title =
          contents ? contents->GetTitle() : std::u16string();
      if (check_title &&
          !base::MatchPattern(tab_title, base::UTF8ToUTF16(*title))) {
        continue;
      }
      if (!url_patterns.is_empty() &&
          !url_patterns.MatchesURL(
              GURL(OrbitTabRegistry::CommittedURLFor(*tab)))) {
        continue;
      }
    }

    result.Append(base::Value(
        OrbitTabRegistry::GetInstance().CreateTabValue(*tab, extension())));
  }
  return RespondNow(WithArguments(std::move(result)));
}

ExtensionFunction::ResponseAction TabsCreateFunction::Run() {
  const base::DictValue* create_properties =
      args().empty() ? nullptr : args()[0].GetIfDict();

  std::string url;
  bool active = true;
  bool pinned = false;
  int32_t window_id = kWindowIdCurrent;

  if (create_properties) {
    if (const std::string* s = create_properties->FindString("url")) {
      url = *s;
    }
    if (std::optional<bool> a = create_properties->FindBool("active")) {
      active = *a;
    }
    if (std::optional<bool> p = create_properties->FindBool("pinned")) {
      pinned = *p;
    }
    if (std::optional<int> w = create_properties->FindInt("windowId")) {
      window_id = *w;
    }
  }
  window_id = ResolveWindowId(this, window_id);

  content::WebContents* created = nullptr;
  int32_t tab_id = 0;
  std::string error;
  if (!OrbitTabRegistry::GetInstance().RequestCreateTab(
          window_id, url, active, pinned, &created, &tab_id, &error)) {
    return RespondNow(Error(error));
  }
  const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(tab_id);
  if (!tab) {
    return RespondNow(Error("Tab was created but could not be resolved"));
  }
  return RespondNow(WithArguments(
      OrbitTabRegistry::GetInstance().CreateTabValue(*tab, extension())));
}

ExtensionFunction::ResponseAction TabsUpdateFunction::Run() {
  size_t next = 0;
  int32_t tab_id;
  if (!args().empty() && args()[0].is_int()) {
    tab_id = args()[0].GetInt();
    next = 1;
  } else {
    // An omitted optional leading argument arrives as a NONE placeholder, not
    // as a missing element -- see ArgumentParser::ParseArgument's AddNull().
    if (!args().empty() && args()[0].is_none()) {
      next = 1;
    }
    const OrbitTabInfo* active_tab = ActiveTabInWindow(CurrentWindowIdFor(this));
    if (!active_tab) {
      return RespondNow(Error("No active tab in the current window"));
    }
    tab_id = active_tab->id;
  }

  const base::DictValue* update_properties =
      args().size() > next ? args()[next].GetIfDict() : nullptr;

  std::string error;
  if (update_properties) {
    if (const std::string* url = update_properties->FindString("url")) {
      if (!OrbitTabRegistry::GetInstance().RequestUpdateTabURL(tab_id, *url,
                                                                &error)) {
        return RespondNow(Error(error));
      }
    }
    if (std::optional<bool> active = update_properties->FindBool("active");
        active && *active) {
      if (!OrbitTabRegistry::GetInstance().RequestActivateTab(tab_id, &error)) {
        return RespondNow(Error(error));
      }
    }
    if (std::optional<bool> pinned = update_properties->FindBool("pinned")) {
      if (!OrbitTabRegistry::GetInstance().RequestSetTabPinned(tab_id, *pinned,
                                                                &error)) {
        return RespondNow(Error(error));
      }
    }
  }

  const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(tab_id);
  if (!tab) {
    return RespondNow(Error("No tab with id: " + base::NumberToString(tab_id)));
  }
  return RespondNow(WithArguments(
      OrbitTabRegistry::GetInstance().CreateTabValue(*tab, extension())));
}

ExtensionFunction::ResponseAction TabsRemoveFunction::Run() {
  if (args().empty()) {
    return RespondNow(Error("tabs.remove requires a tabId or list of tabIds"));
  }

  std::vector<int32_t> tab_ids;
  if (args()[0].is_int()) {
    tab_ids.push_back(args()[0].GetInt());
  } else if (const base::ListValue* list = args()[0].GetIfList()) {
    for (const base::Value& entry : *list) {
      if (!entry.is_int()) {
        return RespondNow(Error("tabIds must be integers"));
      }
      tab_ids.push_back(entry.GetInt());
    }
  } else {
    return RespondNow(Error("tabs.remove requires a tabId or list of tabIds"));
  }

  for (int32_t tab_id : tab_ids) {
    std::string error;
    if (!OrbitTabRegistry::GetInstance().RequestRemoveTab(tab_id, &error)) {
      return RespondNow(Error(error));
    }
  }
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction TabsReloadFunction::Run() {
  // Read by shape, not position: bindings null-pad omitted optional params, so
  // reload(tabId), reload({bypassCache}) and reload() all arrive differently.
  const auto [tab_id, reload_properties] = SplitOptionalTabIdAndDict(args());

  const OrbitTabInfo* tab =
      tab_id.has_value() ? OrbitTabRegistry::GetInstance().GetTab(*tab_id)
                         : ActiveTabInWindow(CurrentWindowIdFor(this));
  if (!tab) {
    return RespondNow(Error(
        tab_id.has_value()
            ? "No tab with id: " + base::NumberToString(*tab_id)
            : std::string("No active tab in the current window")));
  }

  const bool bypass_cache =
      reload_properties ? reload_properties->FindBool("bypassCache").value_or(false)
                        : false;

  if (!tab->web_contents) {
    return RespondNow(Error("That tab has no renderer to reload"));
  }
  // Matches OrbitWebContentsHost::Reload, the path Orbit's own reload control
  // takes, check_for_repost included.
  tab->web_contents->GetController().Reload(
      bypass_cache ? content::ReloadType::BYPASSING_CACHE
                   : content::ReloadType::NORMAL,
      /*check_for_repost=*/false);
  return RespondNow(NoArguments());
}

}  // namespace orbit
