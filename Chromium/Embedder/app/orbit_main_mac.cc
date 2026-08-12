// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Compiled twice: once into the browser binary, once (HELPER_EXECUTABLE
// defined) into every "Orbit Helper*" binary. Only Orbit code that runs
// before the Seatbelt sandbox is applied, so it stays deliberately small.

#ifdef UNSAFE_BUFFERS_BUILD
#pragma allow_unsafe_libc_calls
#endif

#include <dlfcn.h>
#include <errno.h>
#include <libgen.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <memory>

#include "base/allocator/early_zone_registration_apple.h"

#if defined(HELPER_EXECUTABLE)
#include "sandbox/mac/seatbelt_exec.h"  // nogncheck
#endif  // defined(HELPER_EXECUTABLE)

namespace {

using OrbitMainPtr = int (*)(int, const char**);

}  // namespace

int main(int argc, char* argv[]) {
  partition_alloc::EarlyMallocZoneRegistration();

  uint32_t exec_path_size = 0;
  int rv = _NSGetExecutablePath(NULL, &exec_path_size);
  if (rv != -1) {
    fprintf(stderr, "_NSGetExecutablePath: get length failed\n");
    abort();
  }

  std::unique_ptr<char[]> exec_path(new char[exec_path_size]);
  rv = _NSGetExecutablePath(exec_path.get(), &exec_path_size);
  if (rv != 0) {
    fprintf(stderr, "_NSGetExecutablePath: get path failed\n");
    abort();
  }

#if defined(HELPER_EXECUTABLE)
  // Never continue unsandboxed if the browser told us we need one:
  // content::ContentMain() re-checks with CHECK(Seatbelt::IsSandboxed()).
  sandbox::SeatbeltExecServer::CreateFromArgumentsResult seatbelt =
      sandbox::SeatbeltExecServer::CreateFromArguments(exec_path.get(), argc,
                                                       argv);
  if (seatbelt.sandbox_required) {
    if (!seatbelt.server) {
      fprintf(stderr, "Failed to create seatbelt sandbox server.\n");
      abort();
    }
    if (!seatbelt.server->InitializeSandbox()) {
      fprintf(stderr, "Failed to initialize sandbox.\n");
      abort();
    }
  }

  // Running inside .../Orbit Framework.framework/.../Helpers/Orbit Helper*.app/
  // Contents/MacOS/, so the framework binary is four directories up.
  const char rel_path[] = "../../../../Orbit Framework";
#else
  // Running inside Orbit.app/Contents/MacOS/, so the framework is one
  // directory up in Frameworks/.
  const char rel_path[] =
      "../Frameworks/Orbit Framework.framework/Orbit Framework";
#endif  // defined(HELPER_EXECUTABLE)

  const char* parent_dir = dirname(exec_path.get());
  if (!parent_dir) {
    fprintf(stderr, "dirname %s: %s\n", exec_path.get(), strerror(errno));
    abort();
  }

  const size_t parent_dir_len = strlen(parent_dir);
  const size_t rel_path_len = strlen(rel_path);
  const size_t framework_path_size = parent_dir_len + rel_path_len + 2;
  std::unique_ptr<char[]> framework_path(new char[framework_path_size]);
  snprintf(framework_path.get(), framework_path_size, "%s/%s", parent_dir,
           rel_path);

  // RTLD_FIRST: dlsym() below must resolve OrbitMain from this image only.
  void* library =
      dlopen(framework_path.get(), RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!library) {
    fprintf(stderr, "dlopen %s: %s\n", framework_path.get(), dlerror());
    abort();
  }

  const OrbitMainPtr orbit_main =
      reinterpret_cast<OrbitMainPtr>(dlsym(library, "OrbitMain"));
  if (!orbit_main) {
    fprintf(stderr, "dlsym OrbitMain: %s\n", dlerror());
    abort();
  }
  rv = orbit_main(argc, const_cast<const char**>(argv));

  // exit(), not return, so main() is not tail-call-optimised out of crash
  // backtraces.
  exit(rv);
}
