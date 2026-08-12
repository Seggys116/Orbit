// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Required subclass of ExtensionWebContentsObserver (WebContentsUserData
// needs a concrete type to key on). Overrides nothing, unlike Chrome's
// equivalent: Orbit has no error console or crashed-extension reload yet.
// Owns the per-tab ScriptExecutor, which Chrome parks on TabHelper instead.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_WEB_CONTENTS_OBSERVER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_WEB_CONTENTS_OBSERVER_H_

#include <memory>

#include "content/public/browser/web_contents_user_data.h"
#include "extensions/browser/extension_web_contents_observer.h"
#include "extensions/browser/script_executor.h"

namespace orbit {

class OrbitExtensionWebContentsObserver
    : public extensions::ExtensionWebContentsObserver,
      public content::WebContentsUserData<OrbitExtensionWebContentsObserver> {
 public:
  OrbitExtensionWebContentsObserver(const OrbitExtensionWebContentsObserver&) = delete;
  OrbitExtensionWebContentsObserver& operator=(
      const OrbitExtensionWebContentsObserver&) = delete;
  ~OrbitExtensionWebContentsObserver() override;

  // Creates and initializes an instance for `web_contents` if it doesn't
  // already have one; every OrbitWebContentsHost calls this once.
  static void CreateForWebContents(content::WebContents* web_contents);

  // Where chrome.scripting.executeScript/insertCSS/removeCSS reach a tab;
  // see OrbitExtensionsBrowserClient::GetScriptExecutorForTab.
  extensions::ScriptExecutor* script_executor() {
    return script_executor_.get();
  }

 private:
  friend class content::WebContentsUserData<OrbitExtensionWebContentsObserver>;

  explicit OrbitExtensionWebContentsObserver(content::WebContents* web_contents);

  std::unique_ptr<extensions::ScriptExecutor> script_executor_;

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_WEB_CONTENTS_OBSERVER_H_
