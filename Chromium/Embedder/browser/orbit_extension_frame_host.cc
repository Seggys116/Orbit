// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_frame_host.h"

#include <string>
#include <utility>

#include "content/public/browser/web_contents.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/common/extension_set.h"
#include "url/gurl.h"

namespace orbit {

namespace {

// chrome/common/extensions/extension_constants.h's extension_misc::kAppState*;
// that header is chrome/-layer, which Orbit's embedder does not depend on.
constexpr char kAppStateNotInstalled[] = "not_installed";
constexpr char kAppStateInstalled[] = "installed";
constexpr char kAppStateDisabled[] = "disabled";

}  // namespace

OrbitExtensionFrameHost::OrbitExtensionFrameHost(
    content::WebContents* web_contents)
    : ExtensionFrameHost(web_contents) {}

OrbitExtensionFrameHost::~OrbitExtensionFrameHost() = default;

void OrbitExtensionFrameHost::GetAppInstallState(
    const GURL& requestor_url,
    GetAppInstallStateCallback callback) {
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(web_contents_->GetBrowserContext());
  const extensions::ExtensionSet& extensions = registry->enabled_extensions();
  const extensions::ExtensionSet& disabled_extensions =
      registry->disabled_extensions();

  std::string state;
  if (extensions.GetHostedAppByURL(requestor_url)) {
    state = kAppStateInstalled;
  } else if (disabled_extensions.GetHostedAppByURL(requestor_url)) {
    state = kAppStateDisabled;
  } else {
    state = kAppStateNotInstalled;
  }

  std::move(callback).Run(state);
}

}  // namespace orbit
