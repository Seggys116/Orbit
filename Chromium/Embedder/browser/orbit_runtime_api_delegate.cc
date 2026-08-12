// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_runtime_api_delegate.h"

#include "base/logging.h"
#include "build/build_config.h"

namespace orbit {

OrbitRuntimeAPIDelegate::OrbitRuntimeAPIDelegate() = default;
OrbitRuntimeAPIDelegate::~OrbitRuntimeAPIDelegate() = default;

void OrbitRuntimeAPIDelegate::AddUpdateObserver(
    extensions::UpdateObserver* observer) {}

void OrbitRuntimeAPIDelegate::RemoveUpdateObserver(
    extensions::UpdateObserver* observer) {}

void OrbitRuntimeAPIDelegate::ReloadExtension(
    const extensions::ExtensionId& extension_id) {
  LOG(WARNING) << "orbit: chrome.runtime.reload requested for "
              << extension_id << " but reload is not implemented yet";
}

bool OrbitRuntimeAPIDelegate::CheckForUpdates(
    const extensions::ExtensionId& extension_id,
    UpdateCheckCallback callback) {
  // No auto-updater: every check reports "up to date" is meaningless without
  // one, so report unsupported instead of fabricating a result.
  return false;
}

void OrbitRuntimeAPIDelegate::OpenURL(const GURL& uninstall_url) {}

bool OrbitRuntimeAPIDelegate::GetPlatformInfo(
    extensions::api::runtime::PlatformInfo* info) {
  info->os = extensions::api::runtime::PlatformOs::kMac;
#if defined(ARCH_CPU_ARM64)
  info->arch = extensions::api::runtime::PlatformArch::kArm64;
#elif defined(ARCH_CPU_X86_64)
  info->arch = extensions::api::runtime::PlatformArch::kX86_64;
#else
#error "Orbit only ships mac-arm64/mac-x86_64 builds"
#endif
  return true;
}

bool OrbitRuntimeAPIDelegate::RestartDevice(std::string* error_message) {
  *error_message = "Orbit cannot restart the device";
  return false;
}

}  // namespace orbit
