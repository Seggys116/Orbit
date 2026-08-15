// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.contextMenus.{create,update,remove,removeAll}, backed by
// orbit::OrbitMenuManager; hand-parses args(), registered manually by
// OrbitExtensionsBrowserAPIProvider.

#ifndef ORBIT_EMBEDDER_BROWSER_API_CONTEXT_MENUS_ORBIT_CONTEXT_MENUS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_CONTEXT_MENUS_ORBIT_CONTEXT_MENUS_API_H_

#include "extensions/browser/extension_function.h"

namespace orbit {

class ContextMenusCreateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("contextMenus.create", UNKNOWN)

 protected:
  ~ContextMenusCreateFunction() override = default;
  ResponseAction Run() override;
};

class ContextMenusUpdateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("contextMenus.update", UNKNOWN)

 protected:
  ~ContextMenusUpdateFunction() override = default;
  ResponseAction Run() override;
};

class ContextMenusRemoveFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("contextMenus.remove", UNKNOWN)

 protected:
  ~ContextMenusRemoveFunction() override = default;
  ResponseAction Run() override;
};

class ContextMenusRemoveAllFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("contextMenus.removeAll", UNKNOWN)

 protected:
  ~ContextMenusRemoveAllFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_CONTEXT_MENUS_ORBIT_CONTEXT_MENUS_API_H_
