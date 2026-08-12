// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Called directly from OrbitWebContentsHost's WebContentsObserver overrides, no second
// observer. onCreatedNavigationTarget/onTabReplaced are deliberately not dispatched: no
// path exists for either yet.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_NAVIGATION_EVENT_ROUTER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_NAVIGATION_EVENT_ROUTER_H_

class GURL;

namespace content {
class NavigationHandle;
class RenderFrameHost;
class WebContents;
}  // namespace content

namespace orbit {

class OrbitWebNavigationEventRouter {
 public:
  OrbitWebNavigationEventRouter() = delete;

  // content::WebContentsObserver::DidStartNavigation.
  static void DidStartNavigation(content::NavigationHandle* navigation_handle);

  // content::WebContentsObserver::DidFinishNavigation. Dispatches
  // onCommitted/onHistoryStateUpdated/onReferenceFragmentUpdated on commit,
  // onErrorOccurred otherwise.
  static void DidFinishNavigation(content::NavigationHandle* navigation_handle);

  // content::WebContentsObserver::DOMContentLoaded. `web_contents` is the
  // caller's own -- never re-derived from `render_frame_host` since these can
  // run mid-teardown, when that lookup is not guaranteed reliable.
  static void DOMContentLoaded(content::WebContents* web_contents,
                               content::RenderFrameHost* render_frame_host);

  // content::WebContentsObserver::DidFinishLoad.
  static void DidFinishLoad(content::WebContents* web_contents,
                            content::RenderFrameHost* render_frame_host,
                            const GURL& validated_url);

  // content::WebContentsObserver::DidFailLoad.
  static void DidFailLoad(content::WebContents* web_contents,
                          content::RenderFrameHost* render_frame_host,
                          const GURL& validated_url,
                          int error_code);

  // content::WebContentsObserver::RenderFrameDeleted.
  static void RenderFrameDeleted(content::WebContents* web_contents,
                                 content::RenderFrameHost* render_frame_host);

  // content::WebContentsObserver::RenderFrameHostChanged. Aborts any
  // in-flight navigation tracked for `old_host`'s subtree before it (and its
  // OrbitFrameNavigationState) is torn down.
  static void RenderFrameHostPendingDeletion(content::WebContents* web_contents,
                                             content::RenderFrameHost* old_host);
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_NAVIGATION_EVENT_ROUTER_H_
