// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_HISTORY_SERVICE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_HISTORY_SERVICE_H_

#include <set>
#include <string>

#include "base/functional/callback.h"
#include "base/no_destructor.h"
#include "orbit/bridge/orbit_bridge_api.h"

namespace orbit {

void CompleteHistoryResult(void* callback_opaque, const char* result_json);

class OrbitHistoryService {
 public:
  static OrbitHistoryService& GetInstance();

  OrbitHistoryService(const OrbitHistoryService&) = delete;
  OrbitHistoryService& operator=(const OrbitHistoryService&) = delete;

  using ResultCallback = base::OnceCallback<void(const std::string& json)>;

  // A zeroed struct clears it; anything still pending is answered emptily
  // rather than left hanging forever.
  void SetDelegate(const OrbitHistoryDelegate& delegate);

  // False, WITHOUT running `callback`, when no delegate is installed.
  bool Search(const std::string& query_json, ResultCallback callback);
  bool GetVisits(const std::string& url, ResultCallback callback);
  bool AddUrl(const std::string& url,
              const std::string& title,
              ResultCallback callback);
  bool DeleteUrl(const std::string& url, ResultCallback callback);
  bool DeleteRange(double start_ms, double end_ms, ResultCallback callback);
  bool DeleteAll(ResultCallback callback);

  // One HistoryItem, in `search`'s own shape.
  void NotifyVisited(const std::string& history_item_json);

  // `urls_json` is a JSON array of the URL strings actually removed; ignored
  // when `all_history` is true.
  void NotifyVisitRemoved(bool all_history, const std::string& urls_json);

 private:
  friend class base::NoDestructor<OrbitHistoryService>;
  friend void CompleteHistoryResult(void* callback_opaque,
                                    const char* result_json);

  OrbitHistoryService();
  ~OrbitHistoryService();

  // Hands `callback` to the heap so its address can travel as the ABI's
  // `callback_opaque`, and records it so SetDelegate can abandon it.
  void* Retain(ResultCallback callback);
  void Complete(void* token, const std::string& json);

  OrbitHistoryDelegate delegate_ = {};
  std::set<ResultCallback*> pending_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_HISTORY_SERVICE_H_
