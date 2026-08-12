// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Base content::ContentClient's Get*Resource* methods are stubs returning
// empty/null; without this override, Blink parses every UA stylesheet from
// an empty string and <style>/CSS text renders as plain text.

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_CONTENT_CLIENT_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_CONTENT_CLIENT_H_

#include <string>
#include <string_view>

#include "content/public/common/content_client.h"
#include "ui/base/resource/resource_scale_factor.h"

namespace orbit {

class OrbitContentClient : public content::ContentClient {
 public:
  OrbitContentClient();
  OrbitContentClient(const OrbitContentClient&) = delete;
  OrbitContentClient& operator=(const OrbitContentClient&) = delete;
  ~OrbitContentClient() override;

  // content::ContentClient:
  void AddAdditionalSchemes(Schemes* schemes) override;
  std::u16string GetLocalizedString(int message_id) override;
  std::string_view GetDataResource(
      int resource_id,
      ui::ResourceScaleFactor scale_factor) override;
  base::RefCountedMemory* GetDataResourceBytes(int resource_id) override;
  std::string GetDataResourceString(int resource_id) override;
  gfx::Image& GetNativeImageNamed(int resource_id) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_CONTENT_CLIENT_H_
