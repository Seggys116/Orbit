// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.webNavigation.{getFrame,getAllFrames}, backed by ExtensionApiFrameIdMap
// and OrbitFrameNavigationState. Hand-parses args(); registered by OrbitExtensionsBrowserAPIProvider.

#ifndef ORBIT_EMBEDDER_BROWSER_API_WEB_NAVIGATION_ORBIT_WEB_NAVIGATION_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_WEB_NAVIGATION_ORBIT_WEB_NAVIGATION_API_H_

#include "extensions/browser/extension_function.h"

namespace orbit {

class WebNavigationGetFrameFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webNavigation.getFrame", UNKNOWN)

 protected:
  ~WebNavigationGetFrameFunction() override = default;
  ResponseAction Run() override;
};

class WebNavigationGetAllFramesFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webNavigation.getAllFrames", UNKNOWN)

 protected:
  ~WebNavigationGetAllFramesFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_WEB_NAVIGATION_ORBIT_WEB_NAVIGATION_API_H_
