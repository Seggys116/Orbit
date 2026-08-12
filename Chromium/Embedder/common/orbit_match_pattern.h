// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// C++ port of Orbit/Engine/UserScriptMatchPattern.swift's MatchPatternSet --
// same Chrome-extension match-pattern grammar, must stay behaviourally
// identical since Swift is the source of truth for what a pattern means.

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_MATCH_PATTERN_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_MATCH_PATTERN_H_

#include <string>
#include <vector>

class GURL;

namespace orbit {

// An empty/unparseable list matches nothing, never everything.
bool MatchPatternsMatch(const std::vector<std::string>& patterns,
                        const GURL& url);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_MATCH_PATTERN_H_
