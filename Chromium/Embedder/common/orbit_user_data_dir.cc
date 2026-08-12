// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/common/orbit_user_data_dir.h"

#include <string>

#include "base/apple/foundation_util.h"
#include "base/command_line.h"
#include "base/no_destructor.h"

namespace orbit {

namespace {

std::string& PendingUserDataDir() {
  static base::NoDestructor<std::string> pending;
  return *pending;
}

}  // namespace

base::FilePath DefaultOrbitUserDataDir() {
  return base::apple::GetUserLibraryPath()
      .Append("Application Support")
      .Append("Orbit");
}

void SetPendingOrbitUserDataDir(std::string_view path) {
  PendingUserDataDir().assign(path);
}

void ApplyPendingOrbitUserDataDirToCommandLine() {
  const base::FilePath path(PendingUserDataDir());
  if (path.empty() || !path.IsAbsolute()) {
    return;
  }
  base::CommandLine* command_line = base::CommandLine::ForCurrentProcess();
  if (command_line->HasSwitch(kOrbitUserDataDirSwitch)) {
    return;
  }
  command_line->AppendSwitchPath(kOrbitUserDataDirSwitch, path);
}

base::FilePath ResolveOrbitUserDataDir() {
  // Read every time rather than cached: a cache would only add a way for
  // an early accidental call to freeze the wrong answer for the process's life.
  if (base::CommandLine::InitializedForCurrentProcess()) {
    const base::FilePath path =
        base::CommandLine::ForCurrentProcess()->GetSwitchValuePath(
            kOrbitUserDataDirSwitch);
    if (!path.empty() && path.IsAbsolute()) {
      return path;
    }
  }
  return DefaultOrbitUserDataDir();
}

}  // namespace orbit
