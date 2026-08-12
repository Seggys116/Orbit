// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.tabs.{get,getCurrent,query,create,update,remove,reload}, backed by
// OrbitTabRegistry (Orbit has no Browser/TabStripModel); hand-parses args(), registered manually by OrbitExtensionsBrowserAPIProvider.

#ifndef ORBIT_EMBEDDER_BROWSER_API_TABS_ORBIT_TABS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_TABS_ORBIT_TABS_API_H_

#include "extensions/browser/extension_function.h"

namespace orbit {

class TabsGetFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.get", UNKNOWN)

 protected:
  ~TabsGetFunction() override = default;
  ResponseAction Run() override;
};

class TabsGetCurrentFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.getCurrent", UNKNOWN)

 protected:
  ~TabsGetCurrentFunction() override = default;
  ResponseAction Run() override;
};

class TabsQueryFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.query", UNKNOWN)

 protected:
  ~TabsQueryFunction() override = default;
  ResponseAction Run() override;
};

class TabsCreateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.create", UNKNOWN)

 protected:
  ~TabsCreateFunction() override = default;
  ResponseAction Run() override;
};

class TabsUpdateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.update", UNKNOWN)

 protected:
  ~TabsUpdateFunction() override = default;
  ResponseAction Run() override;
};

class TabsRemoveFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.remove", UNKNOWN)

 protected:
  ~TabsRemoveFunction() override = default;
  ResponseAction Run() override;
};

class TabsReloadFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("tabs.reload", UNKNOWN)

 protected:
  ~TabsReloadFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_TABS_ORBIT_TABS_API_H_
