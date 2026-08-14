// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/common/orbit_user_agent.h"

#include <optional>

#include "base/strings/strcat.h"
#include "base/version_info/version_info.h"
#include "components/embedder_support/user_agent_utils.h"
#include "third_party/blink/public/common/user_agent/user_agent_brand_version_type.h"

namespace orbit {

namespace {

// This build is CHROMIUM_BRANDING, so embedder_support only ever offers
// "Chromium" on its own; sites gate their modern paths on the Chrome brand,
// which is the same reason GetProduct() below says Chrome.
constexpr char kChromeBrand[] = "Google Chrome";

// Deliberately just Chromium + Google Chrome + Chromium's own GREASE entry,
// byte-for-byte what stock Chrome sends: Google's own sign-in flow rejects
// any Sec-CH-UA brand list it doesn't recognise, including a real brand this
// build adds on top, so Orbit's brand must never appear here. It stays out
// of GetProduct()/GetUserAgent() above for the same reason.
blink::UserAgentBrandList BrandList(blink::UserAgentBrandVersionType type) {
  const bool full = type == blink::UserAgentBrandVersionType::kFullVersion;
  const std::string chromium_version =
      full ? std::string(version_info::GetVersionNumber())
           : version_info::GetMajorVersionNumber();
  return embedder_support::GenerateBrandVersionList(
      version_info::GetMajorVersionNumberAsInt(), std::string(kChromeBrand),
      chromium_version, type);
}

}  // namespace

std::string GetProduct() {
  return base::StrCat(
      {"Chrome/", version_info::GetMajorVersionNumber(), ".0.0.0"});
}

std::string GetUserAgent() {
  std::optional<std::string> from_command_line =
      embedder_support::GetUserAgentFromCommandLine();
  if (from_command_line.has_value()) {
    return from_command_line.value();
  }
  return embedder_support::BuildUnifiedPlatformUserAgentFromProduct(
      GetProduct());
}

blink::UserAgentMetadata GetUserAgentMetadata() {
  blink::UserAgentMetadata metadata = embedder_support::GetUserAgentMetadata();
  // --user-agent deliberately narrows what upstream reports; a brand list
  // asserted over the top of it would contradict the string being sent.
  if (embedder_support::GetUserAgentFromCommandLine().has_value()) {
    return metadata;
  }
  metadata.brand_version_list =
      BrandList(blink::UserAgentBrandVersionType::kMajorVersion);
  metadata.brand_full_version_list =
      BrandList(blink::UserAgentBrandVersionType::kFullVersion);
  return metadata;
}

}  // namespace orbit
