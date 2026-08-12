// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Bundle-relative path overrides for Orbit's Chromium embedder, macOS only;
// mirrors content/shell/app/paths_apple.{h,mm}.

#ifndef ORBIT_EMBEDDER_APP_ORBIT_PATHS_MAC_H_
#define ORBIT_EMBEDDER_APP_ORBIT_PATHS_MAC_H_

namespace base {
class FilePath;
}

namespace orbit {

// Sets up base::apple::FrameworkBundle to "Orbit Framework.framework".
void OverrideFrameworkBundlePath();

// Sets up base::apple::OuterBundle to the outer .app (Orbit.app or
// Orbit Helper*.app, whichever is running).
void OverrideOuterBundlePath();

// Points content::CHILD_PROCESS_EXE at the plain "Orbit Helper.app" so
// content spawns it for any child type it does not have a specialised
// helper name for.
void OverrideChildProcessPath();

// Sets up base::apple::BaseBundleID from the outer bundle's
// CFBundleIdentifier, matching every process (browser and every helper
// flavour) to the same base ID regardless of their own bundle ID suffixes.
void OverrideBundleID();

// Path to orbit_resources.pak in Orbit Framework.framework/Resources; needed
// before CSS can resolve. Valid only after OverrideFrameworkBundlePath() has run.
base::FilePath GetResourcesPakFilePath();

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_APP_ORBIT_PATHS_MAC_H_
