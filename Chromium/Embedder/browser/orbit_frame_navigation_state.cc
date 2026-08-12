// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_frame_navigation_state.h"

#include "base/containers/fixed_flat_set.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/common/url_constants.h"
#include "url/url_constants.h"

namespace orbit {

DOCUMENT_USER_DATA_KEY_IMPL(OrbitFrameNavigationState);

OrbitFrameNavigationState::OrbitFrameNavigationState(
    content::RenderFrameHost* render_frame_host)
    : content::DocumentUserData<OrbitFrameNavigationState>(render_frame_host) {}
OrbitFrameNavigationState::~OrbitFrameNavigationState() = default;

// static
bool OrbitFrameNavigationState::IsValidUrl(const GURL& url) {
  constexpr auto kValidSchemes = base::MakeFixedFlatSet<std::string_view>({
      content::kChromeUIScheme,
      url::kHttpScheme,
      url::kHttpsScheme,
      url::kFileScheme,
      url::kFtpScheme,
      url::kJavaScriptScheme,
      url::kDataScheme,
      url::kFileSystemScheme,
  });
  if (kValidSchemes.contains(url.scheme())) {
    return true;
  }
  return url.IsAboutBlank() || url.IsAboutSrcdoc();
}

bool OrbitFrameNavigationState::CanSendEvents() const {
  return !error_occurred_ && IsValidUrl(url_);
}

void OrbitFrameNavigationState::StartTrackingDocumentLoad(
    const GURL& url,
    bool is_same_document,
    bool is_from_back_forward_cache,
    bool is_error_page) {
  error_occurred_ = is_error_page;
  url_ = url;
  if (!is_same_document && !is_from_back_forward_cache) {
    is_loading_ = true;
    is_parsing_ = true;
  }
}

GURL OrbitFrameNavigationState::GetUrl() const {
  return url_;
}

void OrbitFrameNavigationState::SetErrorOccurredInFrame() {
  error_occurred_ = true;
}

bool OrbitFrameNavigationState::GetErrorOccurredInFrame() const {
  return error_occurred_;
}

void OrbitFrameNavigationState::SetDocumentLoadCompleted() {
  is_loading_ = false;
}

bool OrbitFrameNavigationState::GetDocumentLoadCompleted() const {
  return !is_loading_;
}

void OrbitFrameNavigationState::SetParsingFinished() {
  is_parsing_ = false;
}

bool OrbitFrameNavigationState::GetParsingFinished() const {
  return !is_parsing_;
}

}  // namespace orbit
