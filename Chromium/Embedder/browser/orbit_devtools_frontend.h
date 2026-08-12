// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// One open inspector: the frontend's OrbitWebContentsHost plus the
// OrbitDevToolsBindings wiring it to the inspected page. At most one per
// inspected host; self-destructs when either host goes away.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_FRONTEND_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_FRONTEND_H_

#include <string>

namespace orbit {

class OrbitWebContentsHost;

// OrbitWebContentsOpenDevTools' implementation. Returns the frontend's host,
// already navigating there; caller owns destroying it. nullptr if `inspected`
// already has an open inspector, or the browser context is gone.
OrbitWebContentsHost* OpenDevToolsFor(OrbitWebContentsHost* inspected,
                                      bool has_inspect_point,
                                      int inspect_x,
                                      int inspect_y);

// The frontend host of `inspected`'s open inspector, or nullptr.
OrbitWebContentsHost* DevToolsFrontendFor(OrbitWebContentsHost* inspected);

// Detaches the CDP client immediately. The frontend host stays valid and is
// still the caller's to destroy. No-op if no inspector is open.
void CloseDevToolsFor(OrbitWebContentsHost* inspected);

// Re-points an already-open inspector at the element under (x, y) of the
// inspected page. No-op if no inspector is open.
void InspectElementInDevTools(OrbitWebContentsHost* inspected, int x, int y);

// See OrbitWebContentsDevToolsStateJSON in orbit_bridge_api.h.
std::string DevToolsStateJSONFor(OrbitWebContentsHost* inspected);

// The inspector's appearance follows orbit::ColorSchemeIsDark() via the same
// prefers-color-scheme media query every page answers. See orbit_color_scheme.h.

// Called from ~OrbitWebContentsHost for every host, inspected or frontend:
// tears the inspector down without calling back into Swift.
void NotifyWebContentsHostDestroyed(OrbitWebContentsHost* host);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_DEVTOOLS_FRONTEND_H_
