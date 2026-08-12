// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Build-validation harness only -- not part of any shipped Orbit bundle.
// dlopen()s "Orbit Framework" from the ninja output directory and calls
// OrbitMain, proving the framework exports and runs it end-to-end.

#ifdef UNSAFE_BUFFERS_BUILD
#pragma allow_unsafe_libc_calls
#endif

#include <dlfcn.h>
#include <libgen.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <memory>

int main(int argc, char* argv[]) {
  // Resolve relative to argv[0]'s directory rather than _NSGetExecutablePath:
  // this tool is invoked directly by a developer/CI from the out dir, never
  // launched by the OS as a bundle, so argv[0] is reliable here.
  const char* self = argv[0];
  std::unique_ptr<char[]> self_copy(new char[strlen(self) + 1]);
  strcpy(self_copy.get(), self);
  const char* out_dir = dirname(self_copy.get());

  const size_t path_size = strlen(out_dir) + 64;
  std::unique_ptr<char[]> framework_path(new char[path_size]);
  snprintf(framework_path.get(), path_size,
           "%s/Orbit Framework.framework/Orbit Framework", out_dir);

  fprintf(stderr, "orbit_selftest: dlopen %s\n", framework_path.get());
  void* library =
      dlopen(framework_path.get(), RTLD_LAZY | RTLD_LOCAL | RTLD_FIRST);
  if (!library) {
    fprintf(stderr, "orbit_selftest: dlopen failed: %s\n", dlerror());
    return 1;
  }

  using OrbitMainPtr = int (*)(int, const char**);
  auto orbit_main = reinterpret_cast<OrbitMainPtr>(dlsym(library, "OrbitMain"));
  if (!orbit_main) {
    fprintf(stderr, "orbit_selftest: dlsym OrbitMain failed: %s\n", dlerror());
    return 1;
  }

  fprintf(stderr, "orbit_selftest: calling OrbitMain\n");
  const char* selftest_argv[] = {"orbit_selftest", "--orbit-selftest"};
  int rv = orbit_main(2, selftest_argv);
  fprintf(stderr, "orbit_selftest: OrbitMain returned %d\n", rv);
  return rv;
}
