// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Deliberately never starts a remote debugging server: Orbit's inspector is
// in-process only, and an open CDP socket is full-privilege remote control.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_MANAGER_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_MANAGER_DELEGATE_H_

#include <string>

#include "content/public/browser/devtools_manager_delegate.h"

namespace content {
class BrowserContext;
class WebContents;
}  // namespace content

namespace orbit {

class OrbitDevToolsManagerDelegate : public content::DevToolsManagerDelegate {
 public:
  OrbitDevToolsManagerDelegate();
  OrbitDevToolsManagerDelegate(const OrbitDevToolsManagerDelegate&) = delete;
  OrbitDevToolsManagerDelegate& operator=(const OrbitDevToolsManagerDelegate&) =
      delete;
  ~OrbitDevToolsManagerDelegate() override;

  // content::DevToolsManagerDelegate:
  content::BrowserContext* GetDefaultBrowserContext() override;
  std::string GetTargetType(content::WebContents* web_contents) override;
  std::string GetTargetTitle(content::WebContents* web_contents) override;
  bool HasBundledFrontendResources() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_MANAGER_DELEGATE_H_
