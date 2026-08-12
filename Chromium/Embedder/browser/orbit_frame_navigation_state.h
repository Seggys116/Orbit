// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Per-document load state chrome.webNavigation needs: mirrors chrome/browser/
// extensions/api/web_navigation/frame_navigation_state.h, minus its
// UNIT_TEST-only extension-scheme toggle.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_FRAME_NAVIGATION_STATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_FRAME_NAVIGATION_STATE_H_

#include "content/public/browser/document_user_data.h"
#include "url/gurl.h"

namespace content {
class RenderFrameHost;
}  // namespace content

namespace orbit {

class OrbitFrameNavigationState
    : public content::DocumentUserData<OrbitFrameNavigationState> {
 public:
  OrbitFrameNavigationState(const OrbitFrameNavigationState&) = delete;
  OrbitFrameNavigationState& operator=(const OrbitFrameNavigationState&) = delete;
  ~OrbitFrameNavigationState() override;

  static bool IsValidUrl(const GURL& url);

  bool CanSendEvents() const;

  void StartTrackingDocumentLoad(const GURL& url,
                                 bool is_same_document,
                                 bool is_from_back_forward_cache,
                                 bool is_error_page);

  GURL GetUrl() const;

  void SetErrorOccurredInFrame();
  bool GetErrorOccurredInFrame() const;

  void SetDocumentLoadCompleted();
  bool GetDocumentLoadCompleted() const;

  void SetParsingFinished();
  bool GetParsingFinished() const;

 private:
  friend class content::DocumentUserData<OrbitFrameNavigationState>;
  DOCUMENT_USER_DATA_KEY_DECL();

  explicit OrbitFrameNavigationState(content::RenderFrameHost* render_frame_host);

  bool error_occurred_ = false;
  bool is_loading_ = false;
  bool is_parsing_ = false;
  GURL url_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_FRAME_NAVIGATION_STATE_H_
