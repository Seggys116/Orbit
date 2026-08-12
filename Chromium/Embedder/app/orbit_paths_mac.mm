// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_paths_mac.h"

#include "base/apple/bundle_locations.h"
#include "base/apple/foundation_util.h"
#include "base/base_paths.h"
#include "base/path_service.h"
#include "base/strings/sys_string_conversions.h"
#include "content/public/common/content_paths.h"

namespace orbit {

namespace {

// Running executable's Contents/ directory: two levels up for the browser
// stub, nine levels up for a helper (see the loop below).
base::FilePath GetContentsPath() {
  base::FilePath path;
  base::PathService::Get(base::FILE_EXE, &path);

  if (base::apple::IsBackgroundOnlyProcess()) {
    for (int i = 0; i < 9; ++i) {
      path = path.DirName();
    }
  } else {
    path = path.DirName().DirName();
  }
  DCHECK_EQ("Contents", path.BaseName().value());
  return path;
}

base::FilePath GetFrameworksPath() {
  return GetContentsPath().Append("Frameworks");
}

}  // namespace

void OverrideFrameworkBundlePath() {
  base::apple::SetOverrideFrameworkBundlePath(
      GetFrameworksPath().Append("Orbit Framework.framework"));
}

void OverrideOuterBundlePath() {
  base::apple::SetOverrideOuterBundlePath(GetContentsPath().DirName());
}

void OverrideChildProcessPath() {
  base::FilePath helper_path = base::apple::FrameworkBundlePath()
                                   .Append("Helpers")
                                   .Append("Orbit Helper.app")
                                   .Append("Contents")
                                   .Append("MacOS")
                                   .Append("Orbit Helper");

  base::PathService::OverrideAndCreateIfNeeded(
      content::CHILD_PROCESS_EXE, helper_path, /*is_absolute=*/true,
      /*create=*/false);
}

void OverrideBundleID() {
  NSBundle* bundle = base::apple::OuterBundle();
  base::apple::SetBaseBundleIDOverride(
      base::SysNSStringToUTF8(bundle.bundleIdentifier));
}

base::FilePath GetResourcesPakFilePath() {
  NSString* pak_path =
      [base::apple::FrameworkBundle() pathForResource:@"orbit_resources"
                                                ofType:@"pak"];
  return base::FilePath([pak_path fileSystemRepresentation]);
}

}  // namespace orbit
