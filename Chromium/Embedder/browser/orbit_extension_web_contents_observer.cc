// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_web_contents_observer.h"

#include <memory>

namespace orbit {

OrbitExtensionWebContentsObserver::OrbitExtensionWebContentsObserver(
    content::WebContents* web_contents)
    : ExtensionWebContentsObserver(web_contents),
      content::WebContentsUserData<OrbitExtensionWebContentsObserver>(*web_contents),
      script_executor_(
          std::make_unique<extensions::ScriptExecutor>(web_contents)) {}

OrbitExtensionWebContentsObserver::~OrbitExtensionWebContentsObserver() = default;

// static
void OrbitExtensionWebContentsObserver::CreateForWebContents(
    content::WebContents* web_contents) {
  content::WebContentsUserData<OrbitExtensionWebContentsObserver>::CreateForWebContents(
      web_contents);
  FromWebContents(web_contents)->Initialize();
}

WEB_CONTENTS_USER_DATA_KEY_IMPL(OrbitExtensionWebContentsObserver);

}  // namespace orbit
