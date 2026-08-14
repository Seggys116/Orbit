// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Owns one content::WebContents and reports navigation state via OrbitWebContentsCallbacks
// so Swift never sees content:: types. Also owns JS execution, user scripts, ScriptChannel.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_CONTENTS_HOST_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_CONTENTS_HOST_H_

#include <map>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/callback_list.h"
#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/values.h"
#include "content/public/browser/certificate_request_result_type.h"
#include "content/public/browser/media_player_id.h"
#include "content/public/browser/render_frame_host_receiver_set.h"
#include "content/public/browser/render_widget_host_observer.h"
#include "content/public/browser/web_contents_delegate.h"
#include "content/public/browser/web_contents_observer.h"
#include "orbit/bridge/orbit_bridge_api.h"
#include "orbit/browser/orbit_user_script_registry.h"
#include "orbit/common/orbit_mojom.mojom.h"
#include "orbit/common/orbit_user_script_spec.h"
#include "third_party/blink/public/mojom/favicon/favicon_url.mojom-forward.h"
#include "ui/gfx/geometry/size.h"

class GURL;
class SkBitmap;

namespace content {
class BrowserContext;
struct ContextMenuParams;
class NavigationHandle;
class Page;
class RenderFrameHost;
class RenderWidgetHost;
class WebContents;
}  // namespace content

namespace gfx {
class Rect;
}  // namespace gfx

namespace net {
class SSLInfo;
}  // namespace net

namespace url {
class Origin;
}  // namespace url

namespace orbit {

class OrbitWebContentsHost : public content::WebContentsObserver,
                             public content::WebContentsDelegate,
                             public content::RenderWidgetHostObserver,
                             public OrbitUserScriptRegistry::Observer,
                             public mojom::ScriptChannel {
 public:
  explicit OrbitWebContentsHost(content::BrowserContext* browser_context);

  // Adopts a WebContents content:: already created (e.g. window.open() from an extension
  // page) instead of creating a new one; otherwise identical to the above constructor.
  explicit OrbitWebContentsHost(std::unique_ptr<content::WebContents> web_contents);

  OrbitWebContentsHost(const OrbitWebContentsHost&) = delete;
  OrbitWebContentsHost& operator=(const OrbitWebContentsHost&) = delete;
  ~OrbitWebContentsHost() override;

  // nullptr if `web_contents` was not created by an OrbitWebContentsHost, e.g. a
  // devtools-internal WebContents's RenderFrameHost.
  static OrbitWebContentsHost* FromWebContents(content::WebContents* web_contents);

  // Any currently open host, or nullptr if none -- the fallback OrbitDownloadManagerDelegate/
  // OrbitPermissionControllerDelegate use when a download/permission outlives its own tab.
  static OrbitWebContentsHost* AnyLiveHost();

  // Recomputes web preferences for every open host and pushes them to its renderer, so a
  // process-global change (e.g. appearance) reaches already-loaded documents too.
  static void NotifyAllPreferencesChanged();

  void SetCallbacks(const OrbitWebContentsCallbacks& callbacks);

  // Returns an NSView*, opaque to callers that never compile Objective-C++.
  void* GetNativeView();

  // Whether the embedder has GetNativeView()'s NSView on-screen. Without this, AppKit's own
  // occlusion notifications can tear the compositor down with no guaranteed event to undo it.
  void SetVisible(bool visible);

  void LoadURL(const std::string& url);
  void Reload(bool bypass_cache);
  void Stop();
  void GoBack();
  void GoForward();
  void GoToOffset(int offset);
  bool CanGoBack();
  bool CanGoForward();
  void Focus();

  // content::WebContents' own native editing commands; see OrbitWebContentsCut/Copy/Paste/
  // SelectAll for why Paste must go through here, not a page script.
  void Cut();
  void Copy();
  void Paste();
  void SelectAll();

  // world 0 = main world, any other = isolated world. `callback` always fires exactly
  // once. `user_gesture` fakes transient activation to reach APIs gated on one.
  void EvaluateJavaScript(const std::string& script,
                          int world,
                          bool user_gesture,
                          OrbitJavaScriptResultCallback callback,
                          void* callback_opaque);

  // Upserts one script (by id) into this tab's own list, on top of OrbitUserScriptRegistry's
  // global list. `json` is one JSON-encoded UserScript.
  void AddLocalUserScript(const std::string& json);

  // orbit::mojom::ScriptChannel -- called from the renderer's
  // window.__orbitPostMessage binding, forwarded to Swift.
  void PostMessage(const std::string& channel, const std::string& json) override;

  void BindScriptChannel(
      content::RenderFrameHost* render_frame_host,
      mojo::PendingAssociatedReceiver<mojom::ScriptChannel> receiver);

  // JSON array of {"id","url","title","offset"} -- see
  // OrbitWebContentsSessionHistory. Returned pointer is this instance's own
  // buffer, overwritten by the next call.
  const char* SessionHistoryJSON();

  void LoadHTML(const std::string& html, const std::string& base_url);
  void SavePage(const std::string& target_path);

  // OrbitWebContentsPrintToPdf's implementation -- see that function's own
  // comment in orbit_bridge_api.h. Always calls `callback` exactly once,
  // asynchronously.
  void PrintToPdf(const std::string& target_path,
                  OrbitPrintToPdfCallback callback,
                  void* callback_opaque);

  void Find(const std::string& text, bool forward, bool match_case, bool find_next);
  void StopFinding(int action);

  void SetZoomFactor(double factor);

  // OrbitWebContentsEnableAutoResize's implementation -- see that function's
  // comment in orbit_bridge_api.h for the contract, including the zoom pin.
  void EnableAutoResize(double min_width,
                        double min_height,
                        double max_width,
                        double max_height);

  // OrbitWebContentsTogglePictureInPicture's implementation -- see that
  // function's own comment for the route entering takes.
  bool TogglePictureInPicture();

  bool HasPictureInPictureVideo();

  // OrbitWebContentsHasPictureInPictureCandidate's implementation.
  bool HasPictureInPictureCandidate();

  void CapturePreview(bool has_rect,
                      double rect_x,
                      double rect_y,
                      double rect_width,
                      double rect_height,
                      double target_width,
                      double target_height,
                      OrbitCapturePreviewCallback callback,
                      void* callback_opaque);

  // Calls `callback` with "" if this host has no callbacks_ set, rather than defaulting
  // to any path. See OrbitDownloadManagerDelegate::DetermineDownloadTarget, the only caller.
  void RequestDownloadTarget(const std::string& download_id,
                             const std::string& suggested_name,
                             const std::string& mime_type,
                             int64_t total_bytes,
                             const std::string& source_url,
                             OrbitDownloadTargetCallback callback,
                             void* callback_opaque);

  // OrbitWebContentsCallbacks.download_progress_changed's implementation --
  // see OrbitDownloadManagerDelegate::OnDownloadUpdated, the only caller. A
  // no-op if this host has no callbacks_.download_progress_changed set.
  void ReportDownloadProgress(const std::string& download_id,
                              int64_t received_bytes,
                              int64_t total_bytes,
                              int state);

  // See OrbitPermissionControllerDelegate::RequestPermissionsFromCurrentDocument, the only
  // caller. Calls `callback` with 0 (deny) if callbacks_.request_permission isn't set.
  void RequestPermissionPrompt(const std::string& kinds_json,
                               const std::string& origin,
                               OrbitPermissionDecisionCallback callback,
                               void* callback_opaque);

  // `callback` is content::'s and must run exactly once, or the navigation hangs with a
  // live URLRequest. CONTINUE only when Swift allows a non-strictly-enforced error; else DENY.
  void HandleCertificateError(
      int cert_error,
      const net::SSLInfo& ssl_info,
      const GURL& request_url,
      bool strict_enforcement,
      base::OnceCallback<void(content::CertificateRequestResultType)> callback);

  // OrbitWebContentsRespondToCertificateError's implementation. A no-op if
  // request_id names no open certificate decision on this host.
  void RespondToCertificateError(uint64_t request_id, bool allow);

  // OrbitWebContentsCallbacks.devtools_closed's implementation -- see
  // orbit_devtools_frontend.h, the only caller. A no-op if this host has no
  // callbacks_.devtools_closed set.
  void NotifyDevToolsClosed();

  // The rest of OrbitWebContentsCallbacks' devtools_* fields, same contract
  // and same single caller (orbit_devtools_frontend.cc): each is a no-op when
  // this host has no such callback set.
  void NotifyDevToolsDockedChanged(bool is_docked);
  void NotifyDevToolsInspectedPageBounds(int x,
                                         int y,
                                         int width,
                                         int height,
                                         bool hide_inspected_page);
  void NotifyDevToolsCloseRequested();
  void NotifyDevToolsBringToFront();

  // `method`/`args` are one chrome.webstorePrivate call; posts via native_extension_request
  // and resolves `callback` when RespondToNativeExtensionRequest answers with the same id.
  // Answers immediately with a synthesized failure envelope if this host has no
  // callbacks_.native_extension_request set.
  void RequestFromNativeExtensionBridge(
      const std::string& method,
      base::ListValue args,
      base::OnceCallback<void(std::string result_json)> callback);

  // OrbitWebContentsRespondToExtensionRequest's implementation. A no-op if
  // request_id names no pending RequestFromNativeExtensionBridge call.
  void RespondToNativeExtensionRequest(const std::string& request_id,
                                       const std::string& result_json);

  // Applies (or, if none is set, clears) OrbitWebContentsHost::
  // GlobalUserAgentOverride() to this tab. Called on construction and by
  // SetGlobalUserAgentOverride for every already-open tab.
  void ApplyUserAgentOverride();

  // OrbitSetUserAgent's implementation -- updates the process-wide default
  // and pushes it to every open OrbitWebContentsHost.
  static void SetGlobalUserAgentOverride(const std::string& user_agent);

  // content::WebContentsObserver:
  void DidStartLoading() override;
  void DidStopLoading() override;
  void LoadProgressChanged(double progress) override;
  void TitleWasSet(content::NavigationEntry* entry) override;
  // Forwards to OrbitWebNavigationEventRouter for every frame (main and
  // sub-) before continuing on to the primary-main-frame-only did_commit/
  // did_finish/did_fail bridge callbacks below -- see this method's body.
  void DidStartNavigation(content::NavigationHandle* navigation_handle) override;
  void DidFinishNavigation(content::NavigationHandle* navigation_handle) override;
  void DOMContentLoaded(content::RenderFrameHost* render_frame_host) override;
  void DidFinishLoad(content::RenderFrameHost* render_frame_host,
                     const GURL& validated_url) override;
  void DidFailLoad(content::RenderFrameHost* render_frame_host,
                   const GURL& validated_url,
                   int error_code) override;
  void RenderFrameDeleted(content::RenderFrameHost* render_frame_host) override;
  void RenderFrameCreated(content::RenderFrameHost* render_frame_host) override;
  void RenderFrameHostChanged(content::RenderFrameHost* old_host,
                              content::RenderFrameHost* new_host) override;
  // Blink's favicon candidate list, refired when a <link rel="icon"> changes or a
  // gating media query flips.
  void DidUpdateFaviconURL(
      content::RenderFrameHost* render_frame_host,
      const std::vector<blink::mojom::FaviconURLPtr>& candidates,
      blink::mojom::FaviconUpdateReason reason) override;
  void MediaPictureInPictureChanged(bool is_picture_in_picture) override;
  // The only way to answer "is there a video to put in PiP, and in which frame" without
  // asking the renderer -- see TogglePictureInPicture.
  void MediaStartedPlaying(const MediaPlayerInfo& media_info,
                           const content::MediaPlayerId& id) override;
  void MediaStoppedPlaying(
      const MediaPlayerInfo& media_info,
      const content::MediaPlayerId& id,
      content::WebContentsObserver::MediaStoppedReason reason) override;
  void MediaMetadataChanged(const MediaPlayerInfo& media_info,
                            const content::MediaPlayerId& id) override;
  void MediaDestroyed(const content::MediaPlayerId& id) override;
  // Closes a still-floating window when the tab navigates away, exactly as
  // chrome's PictureInPictureWindowManager::VideoWebContentsObserver does:
  // content:: itself never ties the two together.
  void PrimaryPageChanged(content::Page& page) override;

  // content::RenderWidgetHostObserver: the two-phase hand-over of sizing to
  // the renderer -- see ApplyAutoResizeToMainFrame.
  void RenderWidgetHostDidUpdateVisualProperties(
      content::RenderWidgetHost* widget_host) override;
  void RenderWidgetHostDestroyed(
      content::RenderWidgetHost* widget_host) override;

  // content::WebContentsDelegate:

  // Base class returns nullptr and drops every navigation content:: refuses to run in its
  // own frame. CURRENT_TAB is navigated here; every other disposition goes to Swift via
  // RequestNewContent.
  content::WebContents* OpenURLFromTab(
      content::WebContents* source,
      const content::OpenURLParams& params,
      base::OnceCallback<void(content::NavigationHandle&)>
          navigation_handle_callback) override;

  // The base class lets the new WebContents' unique_ptr die, destroying window.open()
  // popups before they show. Wraps it and offers it to Swift to adopt as a real tab.
  content::WebContents* AddNewContents(
      content::WebContents* source,
      std::unique_ptr<content::WebContents> new_contents,
      const GURL& target_url,
      WindowOpenDisposition disposition,
      const blink::mojom::WindowFeatures& window_features,
      bool user_gesture,
      bool* was_blocked) override;

  void FindReply(content::WebContents* web_contents,
                int request_id,
                int number_of_matches,
                const gfx::Rect& selection_rect,
                int active_match_ordinal,
                bool final_update) override;
  void ResizeDueToAutoResize(content::WebContents* web_contents,
                             const gfx::Size& new_size) override;

  // Without this override right-click is silently dropped (Orbit installs no
  // WebContentsViewDelegate). Returning true stops that fallback; Swift shows the menu.
  bool HandleContextMenu(content::RenderFrameHost& render_frame_host,
                         const content::ContextMenuParams& params) override;

  // getUserMedia's camera/mic permission routed through content::PermissionController like
  // every other surface. Screen/tab capture has no picker UI yet; refused with NOT_SUPPORTED.
  void RequestMediaAccessPermission(content::WebContents* web_contents,
                                    const content::MediaStreamRequest& request,
                                    content::MediaResponseCallback callback) override;
  bool CheckMediaAccessPermission(content::RenderFrameHost* render_frame_host,
                                  const url::Origin& security_origin,
                                  blink::mojom::MediaStreamType type) override;

  // Without this, StartSession bails with kNotSupported and requestPictureInPicture()
  // rejects. Paired with CreateWindowForVideoPictureInPicture; both halves are required.
  content::PictureInPictureResult EnterPictureInPicture(
      content::WebContents*) override;

  // Every PiP exit path funnels through WebContentsImpl::ExitPictureInPicture. The base
  // class's empty body left the floating window on screen and the PiP flag stuck forever.
  void ExitPictureInPicture() override;

  // Reached via WebContentsImpl::Activate(), notably PiP's "back to tab" control
  // (VideoPictureInPictureWindowControllerImpl::CloseAndFocusInitiator ->
  // FocusInitiator -> Activate). The base class's empty body dropped the request
  // on the floor; Swift needs it to know which tab to switch to.
  void ActivateContents(content::WebContents* contents) override;

  // OrbitUserScriptRegistry::Observer:
  void OnGlobalUserScriptsChanged() override;

 private:
  // Shared by both constructors -- see their own comments.
  void InitWithWebContents(std::unique_ptr<content::WebContents> web_contents);

  void ReportNavigationState();
  void PushScriptsToFrame(content::RenderFrameHost* render_frame_host);
  void PushScriptsToAllFrames();
  std::vector<UserScriptSpec> MergedScripts() const;
  void ReportZoomFactorIfChanged();

  // Hands sizing over to the renderer after first putting the widget at auto_resize_min_;
  // see the .cc for why this needs a separate visual-properties update, not one call.
  void ApplyAutoResizeToMainFrame();
  void EnableAutoResizeOnMainFrame();
  void StopWaitingForAutoResizeMinimum();
  void ReportPictureInPictureState(bool is_active);

  // The player TogglePictureInPicture should present: a playing one if there
  // is one, otherwise any live video player at all. Entries whose frame has
  // gone are skipped rather than trusted.
  std::optional<content::MediaPlayerId> PictureInPictureCandidate() const;
  void ClosePictureInPictureWindow(bool should_pause_video);

  // Fires callbacks_.picture_in_picture_available_changed exactly when
  // PictureInPictureCandidate().has_value() flips, called after every
  // media_players_ mutation (MediaStartedPlaying/MediaStoppedPlaying/
  // MediaMetadataChanged/MediaDestroyed/PrimaryPageChanged).
  void ReportPictureInPictureCandidateIfChanged();

  // Shared by RespondToCertificateError and the destructor's refusal of everything still
  // open. Drops the entry after running the callback, so a duplicate answer can't run it twice.
  void ResolveCertificateDecision(uint64_t request_id, bool allow);
  void DenyPendingCertificateDecisions();

  // `remaining` is every candidate still worth trying, best first, since a candidate can
  // yield no bitmap. `generation` distinguishes a reply for the current icon set from a stale one.
  void DownloadNextFaviconCandidate(uint64_t generation,
                                    std::vector<GURL> remaining);
  void OnFaviconDownloaded(uint64_t generation,
                           std::vector<GURL> remaining,
                           int id,
                           int http_status_code,
                           const GURL& image_url,
                           const std::vector<SkBitmap>& bitmaps,
                           const std::vector<gfx::Size>& sizes);
  void ReportFavicon(const GURL& icon_url, const SkBitmap* bitmap);

  std::unique_ptr<content::WebContents> web_contents_;
  OrbitWebContentsCallbacks callbacks_ = {};

  // Keyed by UserScriptSpec::id; insertion order otherwise irrelevant since
  // match patterns, not order, decide what runs.
  std::map<std::string, UserScriptSpec> local_scripts_;

  // Constructed after web_contents_ exists (RenderFrameHostReceiverSet needs
  // a WebContents* at construction) -- see the constructor.
  std::optional<content::RenderFrameHostReceiverSet<mojom::ScriptChannel>>
      script_channel_receivers_;

  std::string session_history_json_;

  // The icon URL last chosen, so an unchanged refired candidate list doesn't re-download
  // and re-report the same icon. Cleared on every primary main frame navigation.
  std::string reported_favicon_url_;

  // Bumped every time a new candidate list wins, and carried through the
  // download chain so replies for a superseded one are dropped.
  uint64_t favicon_request_generation_ = 0;

  // Only the current find session's request id is forwarded; a stale reply can't race it
  // since Find/StopFinding are UI-thread-synchronous with FindReply's dispatch.
  int find_request_id_ = 0;

  // Last zoom level reported to Swift, so ReportZoomFactorIfChanged (fired for the whole
  // BrowserContext, not just this host) only forwards changes that apply to this tab.
  double last_reported_zoom_level_ = 0.0;
  bool has_reported_zoom_level_ = false;

  // Last value pushed through callbacks_.picture_in_picture_changed, so the
  // destructor's own "left PiP" report cannot double-fire after ExitPictureInPicture.
  bool reported_picture_in_picture_active_ = false;

  // Last value pushed through callbacks_.picture_in_picture_available_changed,
  // so ReportPictureInPictureCandidateIfChanged only forwards an actual flip.
  bool reported_picture_in_picture_candidate_ = false;

  struct MediaPlayerEntry {
    bool has_video = false;
    bool is_playing = false;
  };
  std::map<content::MediaPlayerId, MediaPlayerEntry> media_players_;
  base::CallbackListSubscription zoom_level_changed_subscription_;

  // Empty max = auto-resize was never requested on this host, which is every
  // host but an extension popup's.
  gfx::Size auto_resize_min_;
  gfx::Size auto_resize_max_;
  // The widget whose acknowledgement we are waiting on before handing sizing
  // over, and the one we last handed it over to. Both cleared when the widget
  // goes away.
  raw_ptr<content::RenderWidgetHost> auto_resize_pending_widget_ = nullptr;
  raw_ptr<content::RenderWidgetHost> auto_resize_enabled_widget_ = nullptr;

  // Pending RequestFromNativeExtensionBridge calls, keyed by the request id
  // native_extension_request was posted with.
  std::map<std::string, base::OnceCallback<void(std::string)>>
      pending_native_extension_requests_;
  int next_native_extension_request_id_ = 0;

  // overridable is content::'s own strict_enforcement, inverted: an allow for
  // a request that arrived non-overridable is refused here rather than being
  // trusted to have been hidden in the UI.
  struct PendingCertificateDecision {
    base::OnceCallback<void(content::CertificateRequestResultType)> callback;
    bool overridable = false;
  };
  std::map<uint64_t, PendingCertificateDecision> pending_certificate_decisions_;
  uint64_t next_certificate_request_id_ = 0;

  base::WeakPtrFactory<OrbitWebContentsHost> weak_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_WEB_CONTENTS_HOST_H_
