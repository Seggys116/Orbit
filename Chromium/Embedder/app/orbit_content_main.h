// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Entry point orbit_main_mac.cc dlsym()s for both browser and helper stubs;
// for the helper this runs after the Seatbelt sandbox is already active.

#ifndef ORBIT_EMBEDDER_APP_ORBIT_CONTENT_MAIN_H_
#define ORBIT_EMBEDDER_APP_ORBIT_CONTENT_MAIN_H_

#include "build/build_config.h"

#if BUILDFLAG(IS_MAC)
extern "C" {
__attribute__((visibility("default"))) int OrbitMain(int argc,
                                                      const char** argv);
}  // extern "C"
#endif  // BUILDFLAG(IS_MAC)

#endif  // ORBIT_EMBEDDER_APP_ORBIT_CONTENT_MAIN_H_
