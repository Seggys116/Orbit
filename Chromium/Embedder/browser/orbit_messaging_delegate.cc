// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_messaging_delegate.h"

#include "content/public/browser/web_contents.h"
#include "orbit/browser/orbit_tab_registry.h"

namespace orbit {

OrbitMessagingDelegate::OrbitMessagingDelegate() = default;
OrbitMessagingDelegate::~OrbitMessagingDelegate() = default;

std::optional<base::DictValue> OrbitMessagingDelegate::MaybeGetTabInfo(
    content::WebContents* web_contents) {
  const OrbitTabInfo* tab =
      OrbitTabRegistry::GetInstance().GetTabForWebContents(web_contents);
  if (!tab) {
    // Not a real Orbit tab: extension popups, options pages, and background
    // hosts are their own WebContents but never registered with OrbitTabRegistry.
    return std::nullopt;
  }
  // force_full_access, not extension-scrubbed: the extension being messaged
  // needs to see its own sender's real tab to decide whether to trust it,
  // matching ChromeMessagingDelegate::MaybeGetTabInfo's kDontScrubTab.
  return OrbitTabRegistry::GetInstance().CreateTabValue(
      *tab, /*extension=*/nullptr, /*force_full_access=*/true);
}

content::WebContents* OrbitMessagingDelegate::GetWebContentsByTabId(
    content::BrowserContext* browser_context,
    int tab_id) {
  const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(tab_id);
  return tab ? tab->web_contents.get() : nullptr;
}

void OrbitMessagingDelegate::QueryIncognitoConnectability(
    content::BrowserContext* context,
    const extensions::Extension* extension,
    content::WebContents* web_contents,
    const GURL& url,
    base::OnceCallback<void(bool)> callback) {
  // Orbit has no incognito profile, so false here is a real answer, not a stub:
  // a normal-profile source can never be asking to connect from incognito.
  std::move(callback).Run(false);
}

}  // namespace orbit
