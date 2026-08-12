// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Orbit's extensions::ExtensionsClient -- the per-process global that tells
// the extensions system what it needs about the embedder (registered API
// schemas, webstore URLs, permission warnings, scriptable URL restrictions).
// Registers only extensions::CoreExtensionsAPIProvider, not Chrome's own
// chrome_apps/controlled_frame/chromeos_system_extensions additions.

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_EXTENSIONS_CLIENT_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_EXTENSIONS_CLIENT_H_

#include <set>
#include <string>

#include "extensions/common/extensions_client.h"
#include "orbit/common/orbit_permission_message_provider.h"
#include "url/gurl.h"

namespace orbit {

class OrbitExtensionsClient : public extensions::ExtensionsClient {
 public:
  OrbitExtensionsClient();
  OrbitExtensionsClient(const OrbitExtensionsClient&) = delete;
  OrbitExtensionsClient& operator=(const OrbitExtensionsClient&) = delete;
  ~OrbitExtensionsClient() override;

  // extensions::ExtensionsClient:
  void Initialize() override;
  void InitializeWebStoreUrls(base::CommandLine* command_line) override;
  const extensions::PermissionMessageProvider& GetPermissionMessageProvider()
      const override;
  const std::string GetProductName() override;
  void FilterHostPermissions(
      const extensions::URLPatternSet& hosts,
      extensions::URLPatternSet* new_hosts,
      extensions::PermissionIDSet* permissions) const override;
  void SetScriptingAllowlist(const ScriptingAllowlist& allowlist) override;
  const ScriptingAllowlist& GetScriptingAllowlist() const override;
  extensions::URLPatternSet GetPermittedChromeSchemeHosts(
      const extensions::Extension* extension,
      const extensions::APIPermissionSet& api_permissions) const override;
  bool IsScriptableURL(const GURL& url, std::string* error) const override;
  const GURL& GetWebstoreBaseURL() const override;
  const GURL& GetNewWebstoreBaseURL() const override;
  const GURL& GetWebstoreUpdateURL() const override;
  bool IsBlocklistUpdateURL(const GURL& url) const override;

 private:
  const OrbitPermissionMessageProvider permission_message_provider_;
  ScriptingAllowlist scripting_allowlist_;
  GURL webstore_base_url_;
  GURL new_webstore_base_url_;
  GURL webstore_update_url_;
};

// Constructs and Set()s the single process-wide OrbitExtensionsClient the
// first time it is called; every later call is a no-op.
void EnsureExtensionsClientInitialized();

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_EXTENSIONS_CLIENT_H_
