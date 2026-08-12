// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// UI-thread-only map of Orbit's live tabs/windows, kept in sync by Swift via
// OrbitTabsDelegate; url/title/favicon are read live from WebContents, never cached.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_TAB_REGISTRY_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_TAB_REGISTRY_H_

#include <stdint.h>

#include <map>
#include <set>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/values.h"

namespace content {
class WebContents;
}  // namespace content

namespace extensions {
class Extension;
}  // namespace extensions

namespace orbit {

struct OrbitTabInfo {
  int32_t id = 0;
  int32_t window_id = 0;
  int32_t index = 0;
  bool active = false;
  bool pinned = false;

  // Not owned; cleared by OnTabRemoved. Swift calls that before destroying the
  // WebContents, so this never dangles while an entry exists in `tabs_`.
  raw_ptr<content::WebContents> web_contents = nullptr;
};

struct OrbitWindowInfo {
  int32_t id = 0;
  bool focused = false;
  // One of windows.json's WindowState enum values, pushed by Swift from the
  // real NSWindow (see OrbitWindowsStateChanged).
  std::string state = "normal";
};

// Wraps the raw C function pointers Swift installs via OrbitSetTabsDelegate as
// RepeatingCallbacks; every callback runs synchronously on the UI thread.
struct OrbitTabsDelegate {
  // False on failure (e.g. unknown window_id). On success, out params are the
  // already-created tab's WebContents/id; OnTabCreated has already been called for it.
  base::RepeatingCallback<bool(int32_t window_id,
                               const std::string& url,
                               bool active,
                               bool pinned,
                               content::WebContents** out_web_contents,
                               int32_t* out_tab_id)>
      create_tab;
  base::RepeatingCallback<bool(int32_t tab_id, const std::string& url)>
      update_tab_url;
  base::RepeatingCallback<bool(int32_t tab_id)> activate_tab;
  base::RepeatingCallback<bool(int32_t tab_id)> remove_tab;
  base::RepeatingCallback<bool(int32_t tab_id, bool pinned)> set_tab_pinned;

  bool is_null() const { return create_tab.is_null(); }
};

class OrbitTabRegistry {
 public:
  static OrbitTabRegistry& GetInstance();

  OrbitTabRegistry(const OrbitTabRegistry&) = delete;
  OrbitTabRegistry& operator=(const OrbitTabRegistry&) = delete;

  void SetDelegate(OrbitTabsDelegate delegate);

  // --- Swift -> registry (see orbit_bridge_api.cc's OrbitTabs*/OrbitWindows*
  // implementations). Each fires the matching chrome.tabs/chrome.windows
  // event to every listening extension permitted to see it.

  void OnTabCreated(content::WebContents* web_contents,
                    int32_t tab_id,
                    int32_t window_id,
                    int32_t index,
                    bool active,
                    bool pinned);
  void OnTabRemoved(int32_t tab_id, bool window_closing);
  void OnTabActivated(int32_t tab_id, int32_t window_id, int32_t previous_tab_id);
  void OnTabMoved(int32_t tab_id, int32_t window_id, int32_t from_index, int32_t to_index);
  // Silent: Chrome fires no event when a tab's index merely shifts due to a sibling's
  // insert/remove/pin, though the reported index does change.
  void OnTabIndexChanged(int32_t tab_id, int32_t index);
  void OnTabPinnedChanged(int32_t tab_id, bool pinned);
  // Also fires tabs.onUpdated for url/title/status/favIconUrl changes; called from
  // OrbitWebContentsHost's navigation/title delegates, not pushed separately by Swift.
  void OnTabWebContentsStateChanged(content::WebContents* web_contents);

  void OnWindowCreated(int32_t window_id, bool focused);
  void OnWindowRemoved(int32_t window_id);
  void OnWindowFocusChanged(int32_t window_id);
  void OnWindowStateChanged(int32_t window_id, const std::string& state);

  // --- Registry -> ExtensionFunction reads.

  // Ordered by window id, then by index within that window -- the order
  // chrome.tabs.query and windows.getAll({populate:true}) guarantee.
  std::vector<const OrbitTabInfo*> GetAllTabs() const;
  const OrbitTabInfo* GetTab(int32_t tab_id) const;
  const OrbitTabInfo* GetTabForWebContents(
      const content::WebContents* web_contents) const;
  std::vector<const OrbitWindowInfo*> GetAllWindows() const;
  const OrbitWindowInfo* GetWindow(int32_t window_id) const;
  // WINDOW_ID_CURRENT for calls with no tab (service worker, popup). Deliberately the
  // last-focused window, not the live one: Orbit reports focus lost (id 0) while a popup is open.
  // Returns 0 only when no Orbit window is registered at all; 0 is never a real id, ids start at 1.
  int32_t GetLastFocusedWindowId() const;

  // --- Registry -> delegate, on an ExtensionFunction's behalf. Each returns
  // false and fills `error` on failure (unknown id, or no delegate
  // installed, e.g. running orbit_selftest with no Swift host at all).

  bool RequestCreateTab(int32_t window_id,
                        const std::string& url,
                        bool active,
                        bool pinned,
                        content::WebContents** out_web_contents,
                        int32_t* out_tab_id,
                        std::string* error);
  bool RequestUpdateTabURL(int32_t tab_id, const std::string& url, std::string* error);
  bool RequestActivateTab(int32_t tab_id, std::string* error);
  bool RequestRemoveTab(int32_t tab_id, std::string* error);
  bool RequestSetTabPinned(int32_t tab_id, bool pinned, std::string* error);

  // True if `extension` holds the "tabs" permission, or a host permission (persistent
  // or activeTab) matching the tab's current URL. Mirrors ExtensionTabUtil::ScrubTabForExtension.
  bool HasTabsAccess(const extensions::Extension* extension,
                     const OrbitTabInfo& tab) const;

  // The tab's last committed url -- what chrome.tabs reports as Tab.url and
  // gates permission on. Deliberately not GetVisibleURL(), which is the url
  // of a navigation that may never commit.
  static std::string CommittedURLFor(const OrbitTabInfo& tab);
  // The url of the navigation in flight, empty when none is.
  static std::string PendingURLFor(const OrbitTabInfo& tab);

  // Scrubbed per HasTabsAccess unless force_full_access. Null extension always omits
  // url/title/favIconUrl. force_full_access exists only for MaybeGetTabInfo's sender tab.
  base::DictValue CreateTabValue(const OrbitTabInfo& tab,
                                 const extensions::Extension* extension,
                                 bool force_full_access = false) const;

  // Builds one windows.Window. If `populate_tabs`, "tabs" is set to an array
  // of CreateTabValue results for every tab in this window.
  base::DictValue CreateWindowValue(const OrbitWindowInfo& window,
                                      const extensions::Extension* extension,
                                      bool populate_tabs) const;

 private:
  friend class base::NoDestructor<OrbitTabRegistry>;

  OrbitTabRegistry();
  ~OrbitTabRegistry();

  // Restates chrome.tabs' one-active-tab-per-window invariant, which Orbit's
  // own model does not carry: `activeTabID` is per Space, so more than one
  // tab in a window can hold the flag unless every activation clears it.
  void DeactivateOtherTabsInWindow(int32_t tab_id, int32_t window_id);

  // Whether `extension` may see `url` on `tab_id`. HasTabsAccess is this for the
  // committed url; pendingUrl is gated separately on the pending one.
  bool HasAccessToURL(const extensions::Extension* extension,
                      int32_t tab_id,
                      const std::string& url) const;

  void DispatchTabCreated(const OrbitTabInfo& tab);
  void DispatchTabRemoved(int32_t tab_id, int32_t window_id, bool window_closing);
  void DispatchTabActivated(int32_t tab_id, int32_t window_id);
  void DispatchTabMoved(int32_t tab_id, int32_t window_id, int32_t from_index, int32_t to_index);
  void DispatchTabUpdated(const OrbitTabInfo& tab,
                          std::set<std::string> changed_property_names);
  void DispatchWindowCreated(const OrbitWindowInfo& window);
  void DispatchWindowRemoved(int32_t window_id);
  void DispatchWindowFocusChanged(int32_t window_id);

  std::map<int32_t, OrbitTabInfo> tabs_;
  std::map<int32_t, OrbitWindowInfo> windows_;
  // Never cleared by a focus-lost push, only overwritten by the next window
  // that gains focus -- see GetLastFocusedWindowId. Live focus state is
  // OrbitWindowInfo::focused, which CreateWindowValue reports directly.
  int32_t last_focused_window_id_ = 0;
  OrbitTabsDelegate delegate_;

  // Last dispatched status/url/title/favicon per tab id, so OnTabWebContentsStateChanged
  // (called frequently) only fires onUpdated for fields that actually changed.
  struct LastKnownTabState {
    std::string url;
    std::string title;
    std::string favicon_url;
    bool loading = false;
  };
  std::map<int32_t, LastKnownTabState> last_known_state_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_TAB_REGISTRY_H_
