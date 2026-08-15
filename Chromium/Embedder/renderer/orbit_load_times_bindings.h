// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// window.chrome.loadTimes() / window.chrome.csi() for a //content-tier
// embedder that never links //chrome -- see chrome/renderer/loadtimes_bindings.cc,
// which this mirrors field-for-field and value-for-value.

#ifndef ORBIT_EMBEDDER_RENDERER_ORBIT_LOAD_TIMES_BINDINGS_H_
#define ORBIT_EMBEDDER_RENDERER_ORBIT_LOAD_TIMES_BINDINGS_H_

#include "v8/include/v8-forward.h"

namespace orbit {

void InstallLoadTimesBindings(v8::Local<v8::Context> context);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_RENDERER_ORBIT_LOAD_TIMES_BINDINGS_H_
