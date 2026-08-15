// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_SESSION_SERVICE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_SESSION_SERVICE_H_

#include <cstdint>
#include <string>

#include "base/functional/callback.h"
#include "base/no_destructor.h"
#include "orbit/bridge/orbit_bridge_api.h"

namespace orbit {

class OrbitSessionService {
 public:
  static OrbitSessionService& GetInstance();

  OrbitSessionService(const OrbitSessionService&) = delete;
  OrbitSessionService& operator=(const OrbitSessionService&) = delete;

  using ResultCallback = base::OnceCallback<void(const std::string& json)>;

  // A zeroed struct clears the delegate.
  void SetDelegate(const OrbitSessionsDelegate& delegate);

  // False, with `callback` untouched, when no delegate is installed.
  bool GetRecentlyClosed(int32_t max_results, ResultCallback callback);
  bool Restore(const std::string& session_id, ResultCallback callback);

  void NotifyChanged();

 private:
  friend class base::NoDestructor<OrbitSessionService>;

  OrbitSessionService();
  ~OrbitSessionService();

  OrbitSessionsDelegate delegate_{};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_SESSION_SERVICE_H_
