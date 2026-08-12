// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extensions_client.h"

#include "base/command_line.h"
#include "base/no_destructor.h"
#include "content/public/common/url_constants.h"
#include "extensions/common/core_extensions_api_provider.h"
#include "extensions/common/extension_urls.h"
#include "extensions/common/switches.h"
#include "extensions/common/url_pattern.h"
#include "extensions/common/url_pattern_set.h"
#include "orbit/common/api/orbit_webstore_private_api_provider.h"
#include "orbit/common/orbit_extensions_api_provider.h"

namespace orbit {

OrbitExtensionsClient::OrbitExtensionsClient() {
  AddAPIProvider(std::make_unique<extensions::CoreExtensionsAPIProvider>());
  // chrome.tabs/chrome.windows -- chrome-layer APIs //extensions itself has
  // no implementation of. See orbit_extensions_api_provider.h.
  AddAPIProvider(std::make_unique<OrbitExtensionsAPIProvider>());
  AddAPIProvider(std::make_unique<OrbitWebstorePrivateAPIProvider>());
}

OrbitExtensionsClient::~OrbitExtensionsClient() = default;

void OrbitExtensionsClient::Initialize() {
  InitializeWebStoreUrls(base::CommandLine::ForCurrentProcess());
}

void OrbitExtensionsClient::InitializeWebStoreUrls(
    base::CommandLine* command_line) {
  if (command_line->HasSwitch(extensions::switches::kAppsGalleryURL)) {
    webstore_base_url_ = GURL(command_line->GetSwitchValueASCII(
        extensions::switches::kAppsGalleryURL));
    new_webstore_base_url_ = webstore_base_url_;
  } else {
    webstore_base_url_ = GURL(extension_urls::kChromeWebstoreBaseURL);
    new_webstore_base_url_ = GURL(extension_urls::kNewChromeWebstoreBaseURL);
  }
  webstore_update_url_ = extension_urls::GetDefaultWebstoreUpdateUrl();
}

const extensions::PermissionMessageProvider&
OrbitExtensionsClient::GetPermissionMessageProvider() const {
  return permission_message_provider_;
}

const std::string OrbitExtensionsClient::GetProductName() {
  return "Orbit";
}

void OrbitExtensionsClient::FilterHostPermissions(
    const extensions::URLPatternSet& hosts,
    extensions::URLPatternSet* new_hosts,
    extensions::PermissionIDSet* permissions) const {
  // Orbit has no chrome:// WebUI carve-out (unlike Chrome's chrome://favicon
  // exception), so every chrome:// pattern is dropped, others pass through.
  for (const auto& pattern : hosts) {
    if (pattern.scheme() == content::kChromeUIScheme) {
      continue;
    }
    new_hosts->AddPattern(pattern);
  }
}

void OrbitExtensionsClient::SetScriptingAllowlist(
    const ScriptingAllowlist& allowlist) {
  scripting_allowlist_ = allowlist;
}

const OrbitExtensionsClient::ScriptingAllowlist&
OrbitExtensionsClient::GetScriptingAllowlist() const {
  return scripting_allowlist_;
}

extensions::URLPatternSet OrbitExtensionsClient::GetPermittedChromeSchemeHosts(
    const extensions::Extension* extension,
    const extensions::APIPermissionSet& api_permissions) const {
  // See the FilterHostPermissions comment: Orbit has no chrome:// WebUI
  // surface extensions are permitted host-permission access to today.
  return extensions::URLPatternSet();
}

bool OrbitExtensionsClient::IsScriptableURL(const GURL& url,
                                            std::string* error) const {
  // The gallery is special-cased to prevent extensions from scripting the
  // Web Store UI itself (e.g. to remove a "report abuse" link).
  if (extension_urls::IsWebstoreDomain(url)) {
    if (error) {
      *error = "Cannot access a chrome web store page";
    }
    return false;
  }
  return true;
}

const GURL& OrbitExtensionsClient::GetWebstoreBaseURL() const {
  return webstore_base_url_;
}

const GURL& OrbitExtensionsClient::GetNewWebstoreBaseURL() const {
  return new_webstore_base_url_;
}

const GURL& OrbitExtensionsClient::GetWebstoreUpdateURL() const {
  return webstore_update_url_;
}

bool OrbitExtensionsClient::IsBlocklistUpdateURL(const GURL& url) const {
  // Orbit does not run Google's networked extension blocklist checks;
  // CRX3 signature verification covers install-time integrity instead.
  return false;
}

namespace {

OrbitExtensionsClient* g_orbit_extensions_client = nullptr;

}  // namespace

void EnsureExtensionsClientInitialized() {
  static base::NoDestructor<OrbitExtensionsClient> client;
  if (g_orbit_extensions_client) {
    return;
  }
  g_orbit_extensions_client = client.get();
  extensions::ExtensionsClient::Set(g_orbit_extensions_client);
}

}  // namespace orbit
