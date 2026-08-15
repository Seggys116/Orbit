// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_search_service.h"

#include <memory>
#include <utility>

namespace orbit {

namespace {

// `opaque` is the QueryCallback Query() allocated for this one call, adopted
// here so the one answer the ABI guarantees also deletes it.
void HandleQueryResultFromSwift(void* opaque, const char* error) {
  std::unique_ptr<OrbitSearchService::QueryCallback> callback(
      static_cast<OrbitSearchService::QueryCallback*>(opaque));
  std::move(*callback).Run(error ? std::string(error) : std::string());
}

}  // namespace

// static
OrbitSearchService& OrbitSearchService::GetInstance() {
  static base::NoDestructor<OrbitSearchService> instance;
  return *instance;
}

OrbitSearchService::OrbitSearchService() = default;
OrbitSearchService::~OrbitSearchService() = default;

void OrbitSearchService::SetDelegate(const OrbitSearchDelegate& delegate) {
  delegate_ = delegate;
}

bool OrbitSearchService::Query(const std::string& text,
                               int disposition,
                               bool has_tab_id,
                               int32_t tab_id,
                               QueryCallback callback) {
  if (!delegate_.query) {
    return false;
  }
  auto* callback_holder = new QueryCallback(std::move(callback));
  delegate_.query(delegate_.opaque, text.c_str(), disposition,
                  has_tab_id ? 1 : 0, tab_id, &HandleQueryResultFromSwift,
                  callback_holder);
  return true;
}

}  // namespace orbit
