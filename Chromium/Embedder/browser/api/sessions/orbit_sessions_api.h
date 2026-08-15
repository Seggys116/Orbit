// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_API_SESSIONS_ORBIT_SESSIONS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_SESSIONS_ORBIT_SESSIONS_API_H_

#include <string>

#include "extensions/browser/extension_function.h"

namespace orbit {

class SessionsGetRecentlyClosedFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("sessions.getRecentlyClosed",
                             SESSIONS_GETRECENTLYCLOSED)

 protected:
  ~SessionsGetRecentlyClosedFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnRecentlyClosed(const std::string& json);
};

class SessionsRestoreFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("sessions.restore", SESSIONS_RESTORE)

 protected:
  ~SessionsRestoreFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnRestored(const std::string& json);
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_SESSIONS_ORBIT_SESSIONS_API_H_
