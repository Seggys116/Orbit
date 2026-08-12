// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_tab_registry.h"

#include <algorithm>
#include <tuple>
#include <utility>

#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/web_contents.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"
#include "extensions/common/mojom/context_type.mojom-shared.h"
#include "extensions/common/permissions/permissions_data.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_extension_action_dispatcher.h"
#include "url/gurl.h"

namespace orbit {

namespace {

using extensions::mojom::APIPermissionID;

std::string StatusFor(content::WebContents* web_contents) {
  return web_contents && web_contents->IsLoading() ? "loading" : "complete";
}

// windows.onFocusChanged's contract is windows.WINDOW_ID_NONE (-1) when no
// Orbit window holds focus; the C ABI carries that as 0, which is never a
// real Orbit-assigned window id.
constexpr int32_t kWindowIdNone = -1;

int32_t WindowIdForEvent(int32_t window_id) {
  return window_id == 0 ? kWindowIdNone : window_id;
}

// Every tab/window event this registry dispatches goes through the single
// OrbitBrowserContext -- see orbit_bridge_internal.h's GetOrbitBrowserContext
// comment for why there is exactly one.
extensions::EventRouter* GetEventRouter() {
  content::BrowserContext* browser_context = GetOrbitBrowserContext();
  if (!browser_context) {
    return nullptr;
  }
  return extensions::EventRouter::Get(browser_context);
}

}  // namespace

// static
OrbitTabRegistry& OrbitTabRegistry::GetInstance() {
  static base::NoDestructor<OrbitTabRegistry> instance;
  return *instance;
}

OrbitTabRegistry::OrbitTabRegistry() = default;
OrbitTabRegistry::~OrbitTabRegistry() = default;

void OrbitTabRegistry::SetDelegate(OrbitTabsDelegate delegate) {
  delegate_ = std::move(delegate);
}

// --- Swift -> registry -------------------------------------------------

void OrbitTabRegistry::OnTabCreated(content::WebContents* web_contents,
                                    int32_t tab_id,
                                    int32_t window_id,
                                    int32_t index,
                                    bool active,
                                    bool pinned) {
  OrbitTabInfo tab;
  tab.id = tab_id;
  tab.window_id = window_id;
  tab.index = index;
  tab.active = active;
  tab.pinned = pinned;
  tab.web_contents = web_contents;
  tabs_[tab_id] = tab;
  if (active) {
    DeactivateOtherTabsInWindow(tab_id, window_id);
  }

  last_known_state_[tab_id] = LastKnownTabState{
      .url = CommittedURLFor(tab),
      .title = web_contents ? base::UTF16ToUTF8(web_contents->GetTitle()) : std::string(),
      .favicon_url = std::string(),
      .loading = web_contents && web_contents->IsLoading(),
  };

  DispatchTabCreated(tab);
}

void OrbitTabRegistry::OnTabRemoved(int32_t tab_id, bool window_closing) {
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return;
  }
  int32_t window_id = it->second.window_id;
  tabs_.erase(it);
  last_known_state_.erase(tab_id);
  DispatchTabRemoved(tab_id, window_id, window_closing);
  // After the erase, so the closing tab isn't re-reported. ClearTabState drops the
  // per-tab ExtensionAction entry too, or it would grow unbounded across closed tabs.
  OrbitExtensionActionDispatcher::GetInstance().ClearTabState(
      GetOrbitBrowserContext(), tab_id);
}

void OrbitTabRegistry::DeactivateOtherTabsInWindow(int32_t tab_id,
                                                   int32_t window_id) {
  for (auto& [id, tab] : tabs_) {
    if (id != tab_id && tab.window_id == window_id) {
      tab.active = false;
    }
  }
}

void OrbitTabRegistry::OnTabActivated(int32_t tab_id,
                                      int32_t window_id,
                                      int32_t previous_tab_id) {
  if (auto it = tabs_.find(previous_tab_id); it != tabs_.end()) {
    it->second.active = false;
  }
  // Restates "one active tab per window" on every activation since Orbit's model
  // doesn't enforce it structurally; otherwise chrome.tabs.query({active:true}) can
  // return several tabs.
  DeactivateOtherTabsInWindow(tab_id, window_id);
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    // Reserved id 0, or a tab with no live renderer: Orbit is showing
    // something this registry has no tab for, so the window now has no active
    // tab at all. Deliberately reached after the deactivation above.
    return;
  }
  it->second.active = true;
  DispatchTabActivated(tab_id, window_id);
}

void OrbitTabRegistry::OnTabMoved(int32_t tab_id,
                                  int32_t window_id,
                                  int32_t from_index,
                                  int32_t to_index) {
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end() || from_index == to_index) {
    return;
  }
  it->second.index = to_index;
  it->second.window_id = window_id;
  DispatchTabMoved(tab_id, window_id, from_index, to_index);
}

void OrbitTabRegistry::OnTabIndexChanged(int32_t tab_id, int32_t index) {
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end()) {
    return;
  }
  it->second.index = index;
}

void OrbitTabRegistry::OnTabPinnedChanged(int32_t tab_id, bool pinned) {
  auto it = tabs_.find(tab_id);
  if (it == tabs_.end() || it->second.pinned == pinned) {
    return;
  }
  it->second.pinned = pinned;
  DispatchTabUpdated(it->second, {"pinned"});
}

void OrbitTabRegistry::OnTabWebContentsStateChanged(
    content::WebContents* web_contents) {
  const OrbitTabInfo* tab = GetTabForWebContents(web_contents);
  if (!tab) {
    return;
  }

  LastKnownTabState& last = last_known_state_[tab->id];
  const std::string url = CommittedURLFor(*tab);
  const std::string title = base::UTF16ToUTF8(web_contents->GetTitle());
  const bool loading = web_contents->IsLoading();
  const std::string status = loading ? "loading" : "complete";
  const std::string last_status = last.loading ? "loading" : "complete";

  std::set<std::string> changed_property_names;
  if (url != last.url) {
    changed_property_names.insert("url");
    last.url = url;
  }
  if (title != last.title) {
    changed_property_names.insert("title");
    last.title = title;
  }
  if (status != last_status) {
    changed_property_names.insert("status");
    last.loading = loading;
  }
  if (changed_property_names.empty()) {
    return;
  }
  DispatchTabUpdated(*tab, std::move(changed_property_names));
}

void OrbitTabRegistry::OnWindowCreated(int32_t window_id, bool focused) {
  OrbitWindowInfo window;
  window.id = window_id;
  window.focused = focused;
  windows_[window_id] = window;
  if (focused) {
    last_focused_window_id_ = window_id;
  }
  DispatchWindowCreated(window);
}

void OrbitTabRegistry::OnWindowRemoved(int32_t window_id) {
  if (windows_.erase(window_id) == 0) {
    return;
  }
  DispatchWindowRemoved(window_id);
}

void OrbitTabRegistry::OnWindowFocusChanged(int32_t window_id) {
  for (auto& [id, window] : windows_) {
    window.focused = (id == window_id);
  }
  if (window_id != 0) {
    last_focused_window_id_ = window_id;
  }
  DispatchWindowFocusChanged(window_id);
}

void OrbitTabRegistry::OnWindowStateChanged(int32_t window_id,
                                            const std::string& state) {
  auto it = windows_.find(window_id);
  if (it == windows_.end()) {
    return;
  }
  it->second.state = state;
}

// --- Registry -> ExtensionFunction reads --------------------------------

std::vector<const OrbitTabInfo*> OrbitTabRegistry::GetAllTabs() const {
  std::vector<const OrbitTabInfo*> result;
  result.reserve(tabs_.size());
  for (const auto& [id, tab] : tabs_) {
    result.push_back(&tab);
  }
  // tabs_ is keyed by tab id, i.e. creation order; chrome.tabs.query and
  // windows.getAll({populate:true}) both promise tab-strip order instead.
  std::stable_sort(result.begin(), result.end(),
                   [](const OrbitTabInfo* left, const OrbitTabInfo* right) {
                     return std::tie(left->window_id, left->index) <
                            std::tie(right->window_id, right->index);
                   });
  return result;
}

const OrbitTabInfo* OrbitTabRegistry::GetTab(int32_t tab_id) const {
  auto it = tabs_.find(tab_id);
  return it == tabs_.end() ? nullptr : &it->second;
}

const OrbitTabInfo* OrbitTabRegistry::GetTabForWebContents(
    const content::WebContents* web_contents) const {
  for (const auto& [id, tab] : tabs_) {
    if (tab.web_contents == web_contents) {
      return &tab;
    }
  }
  return nullptr;
}

std::vector<const OrbitWindowInfo*> OrbitTabRegistry::GetAllWindows() const {
  std::vector<const OrbitWindowInfo*> result;
  result.reserve(windows_.size());
  for (const auto& [id, window] : windows_) {
    result.push_back(&window);
  }
  return result;
}

const OrbitWindowInfo* OrbitTabRegistry::GetWindow(int32_t window_id) const {
  auto it = windows_.find(window_id);
  return it == windows_.end() ? nullptr : &it->second;
}

int32_t OrbitTabRegistry::GetLastFocusedWindowId() const {
  if (windows_.find(last_focused_window_id_) != windows_.end()) {
    return last_focused_window_id_;
  }
  // Nothing has focused yet, or the last-focused window closed. Any live window beats
  // none: matches BrowserList's behaviour of never reporting "no window" while windows exist.
  return windows_.empty() ? 0 : windows_.begin()->first;
}

// --- Registry -> delegate ------------------------------------------------

bool OrbitTabRegistry::RequestCreateTab(int32_t window_id,
                                        const std::string& url,
                                        bool active,
                                        bool pinned,
                                        content::WebContents** out_web_contents,
                                        int32_t* out_tab_id,
                                        std::string* error) {
  if (delegate_.is_null()) {
    if (error) {
      *error = "Orbit has no tabs delegate installed";
    }
    return false;
  }
  if (!delegate_.create_tab.Run(window_id, url, active, pinned, out_web_contents,
                                out_tab_id)) {
    if (error) {
      *error = "Could not create a tab in the requested window";
    }
    return false;
  }
  return true;
}

bool OrbitTabRegistry::RequestUpdateTabURL(int32_t tab_id,
                                           const std::string& url,
                                           std::string* error) {
  if (delegate_.is_null() || !delegate_.update_tab_url.Run(tab_id, url)) {
    if (error) {
      *error = "No tab with id " + base::NumberToString(tab_id);
    }
    return false;
  }
  return true;
}

bool OrbitTabRegistry::RequestActivateTab(int32_t tab_id, std::string* error) {
  if (delegate_.is_null() || !delegate_.activate_tab.Run(tab_id)) {
    if (error) {
      *error = "No tab with id " + base::NumberToString(tab_id);
    }
    return false;
  }
  return true;
}

bool OrbitTabRegistry::RequestRemoveTab(int32_t tab_id, std::string* error) {
  if (delegate_.is_null() || !delegate_.remove_tab.Run(tab_id)) {
    if (error) {
      *error = "No tab with id " + base::NumberToString(tab_id);
    }
    return false;
  }
  return true;
}

bool OrbitTabRegistry::RequestSetTabPinned(int32_t tab_id,
                                           bool pinned,
                                           std::string* error) {
  if (delegate_.is_null() || !delegate_.set_tab_pinned.Run(tab_id, pinned)) {
    if (error) {
      *error = "No tab with id " + base::NumberToString(tab_id);
    }
    return false;
  }
  return true;
}

// --- Permission scrubbing --------------------------------------------------

// static
std::string OrbitTabRegistry::CommittedURLFor(const OrbitTabInfo& tab) {
  return tab.web_contents ? tab.web_contents->GetLastCommittedURL().spec()
                          : std::string();
}

// static
std::string OrbitTabRegistry::PendingURLFor(const OrbitTabInfo& tab) {
  if (!tab.web_contents) {
    return std::string();
  }
  content::NavigationEntry* pending =
      tab.web_contents->GetController().GetPendingEntry();
  return pending ? pending->GetVirtualURL().spec() : std::string();
}

bool OrbitTabRegistry::HasAccessToURL(const extensions::Extension* extension,
                                      int32_t tab_id,
                                      const std::string& url) const {
  if (!extension) {
    return false;
  }
  if (extension->permissions_data()->HasAPIPermission(APIPermissionID::kTab)) {
    return true;
  }
  if (url.empty()) {
    return false;
  }
  return extension->permissions_data()->CanAccessPage(GURL(url), tab_id,
                                                      /*error=*/nullptr);
}

bool OrbitTabRegistry::HasTabsAccess(const extensions::Extension* extension,
                                     const OrbitTabInfo& tab) const {
  return HasAccessToURL(extension, tab.id, CommittedURLFor(tab));
}

base::DictValue OrbitTabRegistry::CreateTabValue(
    const OrbitTabInfo& tab,
    const extensions::Extension* extension,
    bool force_full_access) const {
  content::WebContents* contents = tab.web_contents;

  base::DictValue value;
  value.Set("id", tab.id);
  value.Set("index", tab.index);
  value.Set("windowId", tab.window_id);
  value.Set("active", tab.active);
  value.Set("pinned", tab.pinned);
  value.Set("incognito", false);
  value.Set("status", StatusFor(contents));
  // Orbit has no multi-tab selection, no tab groups, no tab freezing and no
  // per-tab discard opt-out, so each of these has exactly one truthful value.
  value.Set("highlighted", tab.active);
  value.Set("groupId", -1);
  value.Set("frozen", false);
  value.Set("autoDiscardable", true);
  value.Set("discarded", contents && contents->WasDiscarded());
  value.Set("audible", contents && contents->IsCurrentlyAudible());
  base::DictValue muted_info;
  muted_info.Set("muted", contents && contents->IsAudioMuted());
  value.Set("mutedInfo", std::move(muted_info));

  const std::string committed_url = CommittedURLFor(tab);
  if (force_full_access || HasAccessToURL(extension, tab.id, committed_url)) {
    value.Set("url", committed_url);
    value.Set("title",
              contents ? base::UTF16ToUTF8(contents->GetTitle()) : std::string());
  }
  const std::string pending_url = PendingURLFor(tab);
  if (!pending_url.empty() &&
      (force_full_access || HasAccessToURL(extension, tab.id, pending_url))) {
    value.Set("pendingUrl", pending_url);
  }
  return value;
}

base::DictValue OrbitTabRegistry::CreateWindowValue(
    const OrbitWindowInfo& window,
    const extensions::Extension* extension,
    bool populate_tabs) const {
  base::DictValue value;
  value.Set("id", window.id);
  value.Set("focused", window.focused);
  value.Set("incognito", false);
  value.Set("state", window.state);
  value.Set("type", "normal");

  if (populate_tabs) {
    base::ListValue tabs;
    for (const OrbitTabInfo* tab : GetAllTabs()) {
      if (tab->window_id == window.id) {
        tabs.Append(base::Value(CreateTabValue(*tab, extension)));
      }
    }
    value.Set("tabs", std::move(tabs));
  }
  return value;
}

// --- Event dispatch --------------------------------------------------------

namespace {

// Rebuilds each extension's tabs.Tab value fresh, scrubbed per its own permissions;
// binds changed_property_names, not a DictValue, since RepeatingCallback needs copyable args.
bool WillDispatchScrubbedTabEvent(
    OrbitTabRegistry* registry,
    int32_t tab_id,
    std::set<std::string> changed_property_names,
    content::BrowserContext* browser_context,
    extensions::mojom::ContextType context_type,
    const extensions::Extension* extension,
    const base::DictValue* listener_filter,
    std::optional<base::ListValue>& event_args_out,
    extensions::mojom::EventFilteringInfoPtr& event_filtering_info_out,
    bool* dispatch_separate_event_out) {
  const OrbitTabInfo* tab = registry->GetTab(tab_id);
  if (!tab) {
    return false;
  }
  base::DictValue tab_value = registry->CreateTabValue(*tab, extension);

  base::ListValue args;
  if (!changed_property_names.empty()) {
    args.Append(base::Value(tab_id));
    base::DictValue changed_properties;
    for (const auto& property : changed_property_names) {
      if (const base::Value* value = tab_value.Find(property)) {
        changed_properties.Set(property, value->Clone());
      }
    }
    args.Append(base::Value(std::move(changed_properties)));
  }
  args.Append(base::Value(std::move(tab_value)));
  event_args_out = std::move(args);
  return true;
}

}  // namespace

void OrbitTabRegistry::DispatchTabCreated(const OrbitTabInfo& tab) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  auto event = std::make_unique<extensions::Event>(
      extensions::events::TABS_ON_CREATED, "tabs.onCreated", base::ListValue());
  event->will_dispatch_callback = base::BindRepeating(
      &WillDispatchScrubbedTabEvent, this, tab.id, std::set<std::string>());
  router->BroadcastEvent(std::move(event));
}

void OrbitTabRegistry::DispatchTabUpdated(
    const OrbitTabInfo& tab,
    std::set<std::string> changed_property_names) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  auto event = std::make_unique<extensions::Event>(
      extensions::events::TABS_ON_UPDATED, "tabs.onUpdated", base::ListValue());
  event->will_dispatch_callback =
      base::BindRepeating(&WillDispatchScrubbedTabEvent, this, tab.id,
                          std::move(changed_property_names));
  router->BroadcastEvent(std::move(event));
}

void OrbitTabRegistry::DispatchTabRemoved(int32_t tab_id,
                                          int32_t window_id,
                                          bool window_closing) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  base::DictValue remove_info;
  remove_info.Set("windowId", window_id);
  remove_info.Set("isWindowClosing", window_closing);

  base::ListValue args;
  args.Append(base::Value(tab_id));
  args.Append(base::Value(std::move(remove_info)));
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::TABS_ON_REMOVED, "tabs.onRemoved", std::move(args)));
}

void OrbitTabRegistry::DispatchTabActivated(int32_t tab_id, int32_t window_id) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  base::DictValue active_info;
  active_info.Set("tabId", tab_id);
  active_info.Set("windowId", window_id);

  base::ListValue args;
  args.Append(base::Value(std::move(active_info)));
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::TABS_ON_ACTIVATED, "tabs.onActivated", std::move(args)));
}

void OrbitTabRegistry::DispatchTabMoved(int32_t tab_id,
                                        int32_t window_id,
                                        int32_t from_index,
                                        int32_t to_index) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  base::DictValue move_info;
  move_info.Set("windowId", window_id);
  move_info.Set("fromIndex", from_index);
  move_info.Set("toIndex", to_index);

  base::ListValue args;
  args.Append(base::Value(tab_id));
  args.Append(base::Value(std::move(move_info)));
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::TABS_ON_MOVED, "tabs.onMoved", std::move(args)));
}

void OrbitTabRegistry::DispatchWindowCreated(const OrbitWindowInfo& window) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  base::ListValue args;
  args.Append(base::Value(CreateWindowValue(window, /*extension=*/nullptr,
                                            /*populate_tabs=*/false)));
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::WINDOWS_ON_CREATED, "windows.onCreated", std::move(args)));
}

void OrbitTabRegistry::DispatchWindowRemoved(int32_t window_id) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  base::ListValue args;
  args.Append(base::Value(window_id));
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::WINDOWS_ON_REMOVED, "windows.onRemoved", std::move(args)));
}

void OrbitTabRegistry::DispatchWindowFocusChanged(int32_t window_id) {
  extensions::EventRouter* router = GetEventRouter();
  if (!router) {
    return;
  }
  base::ListValue args;
  args.Append(base::Value(WindowIdForEvent(window_id)));
  router->BroadcastEvent(std::make_unique<extensions::Event>(
      extensions::events::WINDOWS_ON_FOCUS_CHANGED, "windows.onFocusChanged", std::move(args)));
}

}  // namespace orbit
