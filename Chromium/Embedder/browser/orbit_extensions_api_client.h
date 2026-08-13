// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_API_CLIENT_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_API_CLIENT_H_

#include <map>
#include <memory>

#include "base/memory/raw_ptr.h"
#include "base/memory/scoped_refptr.h"
#include "extensions/browser/api/extensions_api_client.h"
#include "extensions/browser/api/management/management_api_delegate.h"
#include "extensions/browser/api/storage/settings_namespace.h"
#include "extensions/browser/api/storage/settings_observer.h"
#include "orbit/browser/api/webstore_private/orbit_webstore_private_api_delegate.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace value_store {
class ValueStoreFactory;
}  // namespace value_store

namespace extensions {
class MessagingDelegate;
class ValueStoreCache;
}  // namespace extensions

namespace orbit {

class OrbitExtensionsAPIClient : public extensions::ExtensionsAPIClient {
 public:
  OrbitExtensionsAPIClient();
  OrbitExtensionsAPIClient(const OrbitExtensionsAPIClient&) = delete;
  OrbitExtensionsAPIClient& operator=(const OrbitExtensionsAPIClient&) = delete;
  ~OrbitExtensionsAPIClient() override;

  // extensions::ExtensionsAPIClient:
  extensions::MessagingDelegate* GetMessagingDelegate() override;
  extensions::ManagementAPIDelegate* CreateManagementAPIDelegate()
      const override;
  extensions::WebstorePrivateAPIDelegate* GetWebstorePrivateAPIDelegate()
      override;
  // StorageFrontend::Init installs LOCAL itself and asks here for the rest;
  // without this, chrome.storage.sync/managed rejected every call.
  void AddAdditionalValueStoreCaches(
      content::BrowserContext* context,
      const scoped_refptr<value_store::ValueStoreFactory>& factory,
      extensions::SettingsChangedCallback observer,
      std::map<extensions::settings_namespace::Namespace,
               raw_ptr<extensions::ValueStoreCache, CtnExperimental>>* caches)
      override;

 private:
  // MessageService DCHECKs on a null delegate; backed by OrbitTabRegistry so
  // tab-targeted messaging (sender.tab, connect(tabId)) works too.
  std::unique_ptr<extensions::MessagingDelegate> messaging_delegate_;
  // Built eagerly: the core factory registration dereferences it at startup.
  std::unique_ptr<OrbitWebstorePrivateAPIDelegate> webstore_private_delegate_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSIONS_API_CLIENT_H_
