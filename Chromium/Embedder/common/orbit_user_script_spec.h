// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Plain, copyable source-of-truth for a user script -- orbit_mojom.mojom's
// UserScriptSpec is only the wire shape (mojo StructPtrs are move-only,
// unsuited to a value kept in a registry and pushed to N frames).

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_USER_SCRIPT_SPEC_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_USER_SCRIPT_SPEC_H_

#include <string>
#include <vector>

#include "orbit/common/orbit_mojom.mojom.h"

namespace orbit {

struct UserScriptSpec {
  std::string id;
  bool is_stylesheet = false;
  std::string source;
  bool document_start = true;
  std::vector<std::string> match_patterns;
  bool all_frames = false;
};

// Parses the JSON array produced by Swift's JSONEncoder from `[UserScript]`
// (Orbit/Engine/EngineTypes.swift) -- same field names, camelCase, UserScript
// being Codable. Entries that fail to parse are skipped, never fabricated.
std::vector<UserScriptSpec> ParseUserScriptSpecsJSON(const std::string& json);

// Converts to the wire type for one mojo call; the returned vector's structs
// are freshly allocated, safe to send once and discard.
std::vector<mojom::UserScriptSpecPtr> ToMojom(
    const std::vector<UserScriptSpec>& specs);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_USER_SCRIPT_SPEC_H_
