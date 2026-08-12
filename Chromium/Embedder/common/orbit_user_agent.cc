// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit/common/orbit_user_agent.h"

#include <optional>
#include <string_view>

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

// Both come from Chromium/Embedder/BUILD.gn (orbit_product_name,
// orbit_version) so the brand list cannot drift from the bundle's own name
// and version.
constexpr std::string_view kOrbitBrand = ORBIT_PRODUCT_NAME;
constexpr std::string_view kOrbitVersion = ORBIT_BROWSER_VERSION;

std::string OrbitMajorVersion() {
  const size_t dot = kOrbitVersion.find('.');
  return std::string(dot == std::string_view::npos ? kOrbitVersion
                                                   : kOrbitVersion.substr(0, dot));
}

blink::UserAgentBrandList BrandList(blink::UserAgentBrandVersionType type) {
  const bool full = type == blink::UserAgentBrandVersionType::kFullVersion;
  const std::string chromium_version =
      full ? std::string(version_info::GetVersionNumber())
           : version_info::GetMajorVersionNumber();
  const blink::UserAgentBrandVersion orbit_brand = {
      std::string(kOrbitBrand),
      full ? std::string(kOrbitVersion) : OrbitMajorVersion()};
  return embedder_support::GenerateBrandVersionList(
      version_info::GetMajorVersionNumberAsInt(), std::string(kChromeBrand),
      chromium_version, type, orbit_brand);
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
