// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGING_HOST_MANIFEST_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGING_HOST_MANIFEST_H_

#include <memory>
#include <string>

#include "base/files/file_path.h"
#include "base/values.h"
#include "extensions/common/url_pattern_set.h"

namespace orbit {

class OrbitNativeMessagingHostManifest {
 public:
  OrbitNativeMessagingHostManifest(const OrbitNativeMessagingHostManifest&) =
      delete;
  OrbitNativeMessagingHostManifest& operator=(
      const OrbitNativeMessagingHostManifest&) = delete;
  ~OrbitNativeMessagingHostManifest();

  // Valid names match "([a-z0-9_]+\.)*[a-z0-9_]+".
  static bool IsValidName(const std::string& name);

  static std::unique_ptr<OrbitNativeMessagingHostManifest> Load(
      const base::FilePath& file_path,
      std::string* error_message);

  const std::string& name() const { return name_; }
  const base::FilePath& path() const { return path_; }
  const extensions::URLPatternSet& allowed_origins() const {
    return allowed_origins_;
  }

 private:
  OrbitNativeMessagingHostManifest();

  bool Parse(const base::DictValue& dict, std::string* error_message);

  std::string name_;
  base::FilePath path_;
  extensions::URLPatternSet allowed_origins_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGING_HOST_MANIFEST_H_
