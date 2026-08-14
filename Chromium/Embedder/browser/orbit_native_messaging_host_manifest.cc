// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_native_messaging_host_manifest.h"

#include <stddef.h>

#include "base/check.h"
#include "base/json/json_file_value_serializer.h"
#include "base/strings/string_util.h"

namespace orbit {

OrbitNativeMessagingHostManifest::OrbitNativeMessagingHostManifest() = default;
OrbitNativeMessagingHostManifest::~OrbitNativeMessagingHostManifest() = default;

// static
bool OrbitNativeMessagingHostManifest::IsValidName(const std::string& name) {
  if (name.empty()) {
    return false;
  }

  for (size_t i = 0; i < name.size(); ++i) {
    char c = name[i];
    if (!(base::IsAsciiLower(c) || base::IsAsciiDigit(c) || c == '.' ||
          c == '_')) {
      return false;
    }
    if (c == '.' && (i == 0 || name[i - 1] == '.' || i == name.size() - 1)) {
      return false;
    }
  }

  return true;
}

// static
std::unique_ptr<OrbitNativeMessagingHostManifest>
OrbitNativeMessagingHostManifest::Load(const base::FilePath& file_path,
                                       std::string* error_message) {
  DCHECK(error_message);

  JSONFileValueDeserializer deserializer(file_path);
  std::unique_ptr<base::Value> parsed =
      deserializer.Deserialize(nullptr, error_message);
  if (!parsed) {
    return nullptr;
  }

  if (!parsed->is_dict()) {
    *error_message = "Invalid manifest file.";
    return nullptr;
  }

  std::unique_ptr<OrbitNativeMessagingHostManifest> result(
      new OrbitNativeMessagingHostManifest());
  if (!result->Parse(parsed->GetDict(), error_message)) {
    return nullptr;
  }
  return result;
}

bool OrbitNativeMessagingHostManifest::Parse(const base::DictValue& dict,
                                             std::string* error_message) {
  const std::string* name_str = dict.FindString("name");
  if (!name_str || !IsValidName(*name_str)) {
    *error_message = "Invalid value for name.";
    return false;
  }
  name_ = *name_str;

  const std::string* desc_str = dict.FindString("description");
  if (!desc_str || desc_str->empty()) {
    *error_message = "Invalid value for description.";
    return false;
  }

  const std::string* type = dict.FindString("type");
  if (!type || *type != "stdio") {
    *error_message = "Invalid value for type.";
    return false;
  }

  const std::string* path = dict.FindString("path");
  if (!path || (path_ = base::FilePath::FromUTF8Unsafe(*path)).empty()) {
    *error_message = "Invalid value for path.";
    return false;
  }

  const base::ListValue* allowed_origins_list =
      dict.FindList("allowed_origins");
  if (!allowed_origins_list) {
    *error_message =
        "Invalid value for allowed_origins. Expected a list of strings.";
    return false;
  }

  allowed_origins_.ClearPatterns();
  for (const auto& entry : *allowed_origins_list) {
    if (!entry.is_string()) {
      *error_message = "allowed_origins must be list of strings.";
      return false;
    }
    const std::string& pattern_string = entry.GetString();
    URLPattern pattern(URLPattern::SCHEME_EXTENSION);
    URLPattern::ParseResult result = pattern.Parse(pattern_string);
    if (result != URLPattern::ParseResult::kSuccess) {
      *error_message = "Failed to parse pattern \"" + pattern_string +
                       "\": " + URLPattern::GetParseResultString(result);
      return false;
    }
    // The allowed set has to stay a fixed list of extensions.
    if (pattern.match_all_urls() || pattern.match_subdomains()) {
      *error_message = "Pattern \"" + pattern_string + "\" is not allowed.";
      return false;
    }
    allowed_origins_.AddPattern(pattern);
  }

  return true;
}

}  // namespace orbit
