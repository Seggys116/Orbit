// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Effective appearance for prefers-color-scheme; content:: never sets
// preferred_color_scheme (defaults light) unlike chrome/. OverrideWebPreferences
// reads this and re-pushes to open documents so changes apply live.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_COLOR_SCHEME_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_COLOR_SCHEME_H_

namespace orbit {

void SetColorSchemeIsDark(bool dark);
bool ColorSchemeIsDark();

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_COLOR_SCHEME_H_
