// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Backs chrome.runtime's device/update entry points; no auto-updater or device-restart,
// so those report "unsupported" honestly. Fresh implementation, not a port.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_RUNTIME_API_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_RUNTIME_API_DELEGATE_H_

#include "extensions/browser/api/runtime/runtime_api_delegate.h"

namespace orbit {

class OrbitRuntimeAPIDelegate : public extensions::RuntimeAPIDelegate {
 public:
  OrbitRuntimeAPIDelegate();
  OrbitRuntimeAPIDelegate(const OrbitRuntimeAPIDelegate&) = delete;
  OrbitRuntimeAPIDelegate& operator=(const OrbitRuntimeAPIDelegate&) = delete;
  ~OrbitRuntimeAPIDelegate() override;

  // extensions::RuntimeAPIDelegate:
  void AddUpdateObserver(extensions::UpdateObserver* observer) override;
  void RemoveUpdateObserver(extensions::UpdateObserver* observer) override;
  void ReloadExtension(const extensions::ExtensionId& extension_id) override;
  bool CheckForUpdates(const extensions::ExtensionId& extension_id,
                       UpdateCheckCallback callback) override;
  void OpenURL(const GURL& uninstall_url) override;
  bool GetPlatformInfo(extensions::api::runtime::PlatformInfo* info) override;
  bool RestartDevice(std::string* error_message) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_RUNTIME_API_DELEGATE_H_
