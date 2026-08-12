// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/browser/orbit_color_scheme.h"

#include "orbit/browser/orbit_web_contents_host.h"

namespace orbit {

namespace {

bool& IsDarkStorage() {
  static bool is_dark = false;
  return is_dark;
}

}  // namespace

void SetColorSchemeIsDark(bool dark) {
  if (IsDarkStorage() == dark) {
    return;
  }
  IsDarkStorage() = dark;
  OrbitWebContentsHost::NotifyAllPreferencesChanged();
}

bool ColorSchemeIsDark() {
  return IsDarkStorage();
}

}  // namespace orbit
