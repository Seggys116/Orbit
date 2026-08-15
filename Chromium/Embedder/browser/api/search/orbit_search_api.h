// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_API_SEARCH_ORBIT_SEARCH_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_SEARCH_ORBIT_SEARCH_API_H_

#include <string>

#include "extensions/browser/extension_function.h"

namespace orbit {

class SearchQueryFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("search.query", SEARCH_QUERY)

 protected:
  ~SearchQueryFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnQueryComplete(const std::string& error);
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_SEARCH_ORBIT_SEARCH_API_H_
