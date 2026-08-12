// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// The one entry point orbit_bridge_api.cc calls for extension loading,
// keeping extensions::-only types out of the bridge's plain-C translation unit.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_LOADER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_LOADER_H_

#include <string>

#include "orbit/bridge/orbit_bridge_api.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace extensions {
class Extension;
}  // namespace extensions

namespace orbit {

// Why a load is happening, which is the one thing the browser cannot work
// out for itself and the whole extension lifecycle hangs off.
enum class ExtensionLoadReason {
  // A user (or an extension update) asked for this now: a fresh install, an
  // update, a re-enable, a developer "Load Unpacked".
  kUserAction,
  // Bootstrap pass restoring what was installed at last shutdown; gets
  // runtime.onStartup, and onInstalled only if the version changed on disk.
  kBrowserStartup,
};

// Loads the unpacked extension at `directory_path`, activating it in running
// renderers (content scripts live) before `callback` fires once, async, with
// a GetLoadedExtensionsJSON()-shaped payload.
//
// Load path is decided from the manifest against ExtensionPrefs, not `reason`:
//   - no prefs record          -> UnpackedInstaller, onInstalled "install"
//   - prefs at another version -> UnpackedInstaller, onInstalled "update"
//   - prefs at this version    -> ExtensionRegistrar::AddExtension, no onInstalled
void LoadUnpackedExtension(content::BrowserContext* browser_context,
                          const std::string& directory_path,
                          ExtensionLoadReason reason,
                          OrbitLoadExtensionCallback callback,
                          void* callback_opaque);

// Removes `extension_id` for the rest of this run, keeping its ExtensionPrefs
// record (where chrome.permissions.request grants live). Leaves the
// extension's source directory on disk.
void UnloadExtension(content::BrowserContext* browser_context,
                     const std::string& extension_id);

// UnloadExtension plus that record, for an extension the user is getting rid
// of rather than one being reloaded.
void UninstallExtension(content::BrowserContext* browser_context,
                        const std::string& extension_id);

// Tells runtime.onInstalled which version is being replaced, since every
// Orbit update unloads the running copy before ExtensionStore touches its
// files, so the registry has already forgotten the predecessor.
// Must be called from OrbitExtensionRegistrarDelegate::PreAddExtension only:
// the one point between LazyEventDispatchUtil writing and reading that pref.
void RestorePreviousVersionForOnInstalled(
    content::BrowserContext* browser_context,
    const extensions::Extension& extension);

// One object per enabled-or-disabled extension: {"id","name","version",
// "directory","iconPath","hasToolbarAction","manifestVersion","isEnabled"}.
std::string GetLoadedExtensionsJSON(content::BrowserContext* browser_context);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_LOADER_H_
