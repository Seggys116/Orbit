// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// content::VideoOverlayWindow: the PiP floating panel. Compositor plumbing follows
// unbounded_surface_window_mac.mm; header must declare no ObjC-typed member (included from C++).

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_VIDEO_OVERLAY_WINDOW_MAC_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_VIDEO_OVERLAY_WINDOW_MAC_H_

#include <memory>

namespace content {
class VideoOverlayWindow;
class VideoPictureInPictureWindowController;
}  // namespace content

namespace orbit {

std::unique_ptr<content::VideoOverlayWindow> CreateVideoOverlayWindowMac(
    content::VideoPictureInPictureWindowController* controller);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_VIDEO_OVERLAY_WINDOW_MAC_H_
