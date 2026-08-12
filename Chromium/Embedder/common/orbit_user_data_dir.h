// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Where every Orbit process keeps its profile state. Carried on the command
// line, not a framework-global, because a helper is a separate exec() and
// never sees the browser's globals. Deliberately dependency-free (base/ only).

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_USER_DATA_DIR_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_USER_DATA_DIR_H_

#include <string_view>

#include "base/files/file_path.h"

namespace orbit {

// --orbit-user-data-dir=<absolute path>.
inline constexpr char kOrbitUserDataDirSwitch[] = "orbit-user-data-dir";

// <Library>/Application Support/Orbit. The production profile: what an
// unswitched process resolves to, and the only directory the shipped browser
// and the user's installed extensions ever use.
base::FilePath DefaultOrbitUserDataDir();

// Recorded before base::CommandLine exists -- Swift calls this before
// OrbitMain. An empty or relative path clears the override.
void SetPendingOrbitUserDataDir(std::string_view path);

// Moves whatever SetPendingOrbitUserDataDir recorded onto this process's own
// command line. Must run after base::CommandLine::Init and before anything
// reads the directory -- OrbitMainDelegate::BasicStartupComplete() is the
// first hook that satisfies both.
void ApplyPendingOrbitUserDataDirToCommandLine();

// This process's user data directory: the switch value when one is present
// and absolute, otherwise DefaultOrbitUserDataDir().
base::FilePath ResolveOrbitUserDataDir();

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_USER_DATA_DIR_H_
