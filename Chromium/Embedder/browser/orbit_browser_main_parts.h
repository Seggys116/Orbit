// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Modelled on shell_browser_main_parts.h; unlike content_shell, Swift
// creates windows/WebContents through orbit_bridge_api.h, not this class.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_BROWSER_MAIN_PARTS_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_BROWSER_MAIN_PARTS_H_

#include <memory>

#include "content/public/browser/browser_main_parts.h"
#include "orbit/browser/orbit_native_nested_loop_guard.h"

namespace display {
class ScopedNativeScreen;
}  // namespace display

namespace extensions {
class ExtensionsAPIClient;
}  // namespace extensions

namespace orbit {

class OrbitBrowserContext;
class OrbitExtensionsBrowserClient;

class OrbitBrowserMainParts : public content::BrowserMainParts {
 public:
  OrbitBrowserMainParts();
  OrbitBrowserMainParts(const OrbitBrowserMainParts&) = delete;
  OrbitBrowserMainParts& operator=(const OrbitBrowserMainParts&) = delete;
  ~OrbitBrowserMainParts() override;

  // content::BrowserMainParts:
  int PreEarlyInitialization() override;
  int PreMainMessageLoopRun() override;
  void WillRunMainMessageLoop(
      std::unique_ptr<base::RunLoop>& run_loop) override;
  void PostMainMessageLoopRun() override;

  OrbitBrowserContext* browser_context() { return browser_context_.get(); }

 private:
  // display::Screen::Get() (required by RenderWidgetHostViewMac) is null
  // until this exists; mirrors chrome_browser_main_extra_parts_mac.mm.
  std::unique_ptr<display::ScopedNativeScreen> screen_;

  std::unique_ptr<OrbitBrowserContext> browser_context_;

  std::unique_ptr<OrbitExtensionsBrowserClient> extensions_browser_client_;
  std::unique_ptr<extensions::ExtensionsAPIClient> extensions_api_client_;

  // Keeps UI-thread tasks running while AppKit/SwiftUI has a native nested
  // run loop on the stack (menu tracking, modal panels).
  std::unique_ptr<OrbitNativeNestedLoopGuard> native_nested_loop_guard_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_BROWSER_MAIN_PARTS_H_
