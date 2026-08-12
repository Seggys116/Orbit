// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/browser/orbit_devtools_manager_delegate.h"

#include "base/strings/utf_string_conversions.h"
#include "content/public/browser/devtools_agent_host.h"
#include "content/public/browser/web_contents.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_web_contents_host.h"

namespace orbit {

OrbitDevToolsManagerDelegate::OrbitDevToolsManagerDelegate() = default;

OrbitDevToolsManagerDelegate::~OrbitDevToolsManagerDelegate() = default;

content::BrowserContext*
OrbitDevToolsManagerDelegate::GetDefaultBrowserContext() {
  return GetOrbitBrowserContext();
}

std::string OrbitDevToolsManagerDelegate::GetTargetType(
    content::WebContents* web_contents) {
  return OrbitWebContentsHost::FromWebContents(web_contents)
             ? content::DevToolsAgentHost::kTypePage
             : content::DevToolsAgentHost::kTypeOther;
}

std::string OrbitDevToolsManagerDelegate::GetTargetTitle(
    content::WebContents* web_contents) {
  return base::UTF16ToUTF8(web_contents->GetTitle());
}

bool OrbitDevToolsManagerDelegate::HasBundledFrontendResources() {
  return true;
}

}  // namespace orbit
