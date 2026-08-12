// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_content_main.h"

#include "build/build_config.h"
#include "content/public/app/content_main.h"
#include "orbit_main_delegate.h"
#include "orbit_paths_mac.h"

#if BUILDFLAG(IS_MAC)
int OrbitMain(int argc, const char** argv) {
  orbit::OrbitMainDelegate delegate;
  content::ContentMainParams params(&delegate);
  params.argc = argc;
  params.argv = argv;

  // Must run before content::ContentMain(): it reads CFBundleIdentifier and
  // wants to know which bundle (Orbit.app or a helper) it is running from.
  orbit::OverrideFrameworkBundlePath();
  orbit::OverrideOuterBundlePath();
  orbit::OverrideChildProcessPath();
  orbit::OverrideBundleID();

  return content::ContentMain(std::move(params));
}
#endif  // BUILDFLAG(IS_MAC)
