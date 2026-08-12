// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_user_script_spec.h"

#include "base/json/json_reader.h"
#include "base/values.h"

namespace orbit {

std::vector<UserScriptSpec> ParseUserScriptSpecsJSON(const std::string& json) {
  std::vector<UserScriptSpec> result;
  std::optional<base::ListValue> parsed =
      base::JSONReader::ReadList(json, base::JSON_PARSE_RFC);
  if (!parsed) {
    return result;
  }

  for (const base::Value& entry : *parsed) {
    if (!entry.is_dict()) {
      continue;
    }
    const base::DictValue& dict = entry.GetDict();

    const std::string* id = dict.FindString("id");
    const std::string* source = dict.FindString("source");
    const std::string* kind = dict.FindString("kind");
    const std::string* injection_time = dict.FindString("injectionTime");
    const base::ListValue* patterns = dict.FindList("matchPatterns");
    if (!id || !source || !kind || !injection_time || !patterns) {
      continue;
    }

    UserScriptSpec spec;
    spec.id = *id;
    spec.source = *source;
    spec.is_stylesheet = (*kind == "stylesheet");
    spec.document_start = (*injection_time != "documentEnd");
    spec.all_frames = dict.FindBool("allFrames").value_or(false);
    for (const base::Value& pattern : *patterns) {
      if (pattern.is_string()) {
        spec.match_patterns.push_back(pattern.GetString());
      }
    }
    result.push_back(std::move(spec));
  }
  return result;
}

std::vector<mojom::UserScriptSpecPtr> ToMojom(
    const std::vector<UserScriptSpec>& specs) {
  std::vector<mojom::UserScriptSpecPtr> result;
  result.reserve(specs.size());
  for (const UserScriptSpec& spec : specs) {
    auto wire = mojom::UserScriptSpec::New();
    wire->id = spec.id;
    wire->kind = spec.is_stylesheet ? mojom::UserScriptKind::kStylesheet
                                    : mojom::UserScriptKind::kJavaScript;
    wire->source = spec.source;
    wire->injection_time = spec.document_start
                                ? mojom::UserScriptInjectionTime::kDocumentStart
                                : mojom::UserScriptInjectionTime::kDocumentEnd;
    wire->match_patterns = spec.match_patterns;
    wire->all_frames = spec.all_frames;
    result.push_back(std::move(wire));
  }
  return result;
}

}  // namespace orbit
