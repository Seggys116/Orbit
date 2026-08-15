// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_SEARCH_SERVICE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_SEARCH_SERVICE_H_

#include <cstdint>
#include <string>

#include "base/functional/callback.h"
#include "base/no_destructor.h"
#include "orbit/bridge/orbit_bridge_api.h"

namespace orbit {

class OrbitSearchService {
 public:
  static OrbitSearchService& GetInstance();

  OrbitSearchService(const OrbitSearchService&) = delete;
  OrbitSearchService& operator=(const OrbitSearchService&) = delete;

  // "" is success; anything else reaches runtime.lastError.
  using QueryCallback = base::OnceCallback<void(const std::string& error)>;

  // A zeroed struct clears the delegate.
  void SetDelegate(const OrbitSearchDelegate& delegate);

  // False, with `callback` untouched, when no delegate is installed: reporting
  // a search that never happened as a success is the failure mode here.
  bool Query(const std::string& text,
             int disposition,
             bool has_tab_id,
             int32_t tab_id,
             QueryCallback callback);

 private:
  friend class base::NoDestructor<OrbitSearchService>;

  OrbitSearchService();
  ~OrbitSearchService();

  OrbitSearchDelegate delegate_{};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_SEARCH_SERVICE_H_
