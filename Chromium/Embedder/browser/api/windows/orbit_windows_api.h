// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.windows.{get,getCurrent,getLastFocused,getAll}, read-only, backed
// by orbit::OrbitTabRegistry. windows.create/update/remove are not
// implemented -- see common/api/windows.json's file comment.

#ifndef ORBIT_EMBEDDER_BROWSER_API_WINDOWS_ORBIT_WINDOWS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_WINDOWS_ORBIT_WINDOWS_API_H_

#include "extensions/browser/extension_function.h"

namespace orbit {

class WindowsGetFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("windows.get", UNKNOWN)

 protected:
  ~WindowsGetFunction() override = default;
  ResponseAction Run() override;
};

class WindowsGetCurrentFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("windows.getCurrent", UNKNOWN)

 protected:
  ~WindowsGetCurrentFunction() override = default;
  ResponseAction Run() override;
};

class WindowsGetLastFocusedFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("windows.getLastFocused", UNKNOWN)

 protected:
  ~WindowsGetLastFocusedFunction() override = default;
  ResponseAction Run() override;
};

class WindowsGetAllFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("windows.getAll", UNKNOWN)

 protected:
  ~WindowsGetAllFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_WINDOWS_ORBIT_WINDOWS_API_H_
