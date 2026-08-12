// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// The only surface Swift calls into. Swift dlsym()s each symbol by
// @convention(c) function pointer rather than including this header, so
// every type below is a plain C POD.

#ifndef ORBIT_EMBEDDER_BRIDGE_ORBIT_BRIDGE_API_H_
#define ORBIT_EMBEDDER_BRIDGE_ORBIT_BRIDGE_API_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OrbitWebContentsHostOpaque* OrbitWebContentsHandle;

// OrbitApplication.swift's -sendEvent: override calls these around every
// native event. identifier is the originating NSEvent's pointer value,
// reinterpreted only, never dereferenced.
__attribute__((visibility("default")))
void OrbitNotifyWillRunNativeEvent(void* observer, uintptr_t identifier);

__attribute__((visibility("default")))
void OrbitNotifyDidRunNativeEvent(void* observer, uintptr_t identifier);

// Fired once, on the UI thread, when OrbitBrowserContext is constructed --
// the earliest point OrbitWebContentsCreate can succeed. Must register this
// before OrbitMain; never fired if the browser exits first.
typedef void (*OrbitBrowserReadyCallback)(void* opaque);
__attribute__((visibility("default")))
void OrbitSetBrowserReadyCallback(OrbitBrowserReadyCallback callback, void* opaque);

// Runs the base::RunLoop::QuitClosure saved by WillRunMainMessageLoop.
// Returns 0 and does nothing if the browser has not reached that point yet
// (the caller must not read that as "already shut down").
__attribute__((visibility("default")))
int OrbitRequestBrowserQuit(void);

// version_info::GetVersionNumber() of the linked Chromium, e.g.
// "151.0.7922.109". Never null; valid for the process's lifetime.
__attribute__((visibility("default")))
const char* OrbitChromiumVersionNumber(void);

// "orbit-engine-build: dcheck=1" or "=0", from DCHECK_IS_ON(). `Scripts/chromium
// verify-engine` reads this literal straight out of the linked Mach-O.
__attribute__((visibility("default")))
const char* OrbitEngineBuildMarker(void);

// GetPath() of the single OrbitBrowserContext. Empty until the ready
// callback above has fired.
__attribute__((visibility("default")))
const char* OrbitBrowserContextPath(void);

// Points every process (browser + helpers) in this launch at `path` instead
// of the production default; must be absolute (null/empty/relative is a
// no-op), and called before OrbitMain -- the value is transferred onto the
// command line during BasicStartupComplete, so calling it later does nothing.
__attribute__((visibility("default")))
void OrbitSetUserDataDirectory(const char* path);

// See OrbitWebContentsCallbacks.will_begin_download's own comment.
typedef void (*OrbitDownloadTargetCallback)(void* opaque, const char* target_path);

// See OrbitWebContentsCallbacks.request_permission's own comment.
typedef void (*OrbitPermissionDecisionCallback)(void* opaque, int decision);

// One WebContentsHost's delegate callbacks. Pointers must stay valid until
// OrbitWebContentsDestroy or a later Set call replaces them; `opaque` is
// handed back unmodified on every call, always on the UI (main) thread.
typedef struct {
  void* opaque;

  // is_loading/can_go_back/can_go_forward are 0/1. url is UTF-8, never null.
  void (*navigation_state_changed)(void* opaque,
                                    int is_loading,
                                    int can_go_back,
                                    int can_go_forward,
                                    const char* url);

  // 0.0 ... 1.0.
  void (*load_progress_changed)(void* opaque, double progress);

  void (*title_changed)(void* opaque, const char* title);

  // kind: 0=other 1=typed 2=linkActivated 3=formSubmitted 4=backForward
  // 5=reload 6=redirect 7=restored -- see orbit_web_contents_host.mm's
  // PageTransitionToKind for the mapping this mirrors.
  void (*did_commit)(void* opaque, const char* url, int kind);

  // http_status_code is 0 if the response carried none (e.g. a file: load).
  void (*did_finish)(void* opaque, const char* url, int http_status_code);

  // error_code is a net::Error (negative). description is UTF-8, never null.
  void (*did_fail)(void* opaque,
                    const char* url,
                    int error_code,
                    const char* description);

  // A page-injected script called window.__orbitPostMessage(channel, json).
  // channel is one of the *ObserverScript.channelName constants; json is
  // that channel's own payload shape. Both UTF-8, never null.
  void (*did_receive_script_message)(void* opaque,
                                     const char* channel,
                                     const char* json);

  // Fired after an OrbitWebContentsFind request produces a browser-side
  // reply. is_final_update is 0/1; a Find call can produce several updates,
  // the last with is_final_update set.
  void (*find_result_changed)(void* opaque,
                              int32_t active_match_ordinal,
                              int32_t match_count,
                              int is_final_update);

  // Fired whenever this tab's effective zoom changes: an explicit
  // SetZoomFactor call, a same-host tab elsewhere changing it (zoom is
  // per-host, not per-tab), or navigating to a host with a stored zoom.
  void (*zoom_factor_changed)(void* opaque, double factor);

  // The document's own laid-out size, in DIPs, clamped to
  // OrbitWebContentsEnableAutoResize's bounds. Only fired for a handle that
  // call was made on.
  void (*preferred_size_changed)(void* opaque, double width, double height);

  // Fired once per download needing a target path (falls back to any other
  // open tab if this one has closed). download_id is the download's own GUID
  // (base::Uuid-parseable), never null, and correlates with the same
  // argument on download_progress_changed. suggested_name/mime_type are
  // UTF-8; total_bytes is 0 if unknown; source_url is the final URL in the
  // redirect chain. `callback` must be called exactly once, async; NULL/""
  // cancels, otherwise it must be the full, unique destination path (parent
  // directory must already exist).
  void (*will_begin_download)(void* opaque,
                              const char* download_id,
                              const char* suggested_name,
                              const char* mime_type,
                              int64_t total_bytes,
                              const char* source_url,
                              OrbitDownloadTargetCallback callback,
                              void* callback_opaque);

  // Fired on every DownloadItem::Observer::OnDownloadUpdated for a tracked
  // download. state: 0=pending 1=inProgress 2=paused 3=completed
  // 4=cancelled 5=interrupted.
  void (*download_progress_changed)(void* opaque,
                                    const char* download_id,
                                    int64_t received_bytes,
                                    int64_t total_bytes,
                                    int state);

  // Fired once per permission request with no stored decision yet (covers
  // geolocation/notifications/MIDI/sensors and getUserMedia camera/mic).
  // kinds_json is a JSON array of PermissionKind raw values, never empty; a
  // requested type this build cannot map is denied before reaching Swift.
  // origin is UTF-8 scheme://host[:port]. `callback` must be called exactly
  // once, async, with 0=deny 1=allow 2=allowAlways 3=denyAlways;
  // allowAlways/denyAlways apply to every kind in the request and persist,
  // allow/deny do not.
  void (*request_permission)(void* opaque,
                             const char* kinds_json,
                             const char* origin,
                             OrbitPermissionDecisionCallback callback,
                             void* callback_opaque);

  // A native chrome.webstorePrivate call only Swift can answer (real install
  // state, consent UI, CRX3-verified install). method is one of
  // "beginInstallWithManifest3"/"completeInstall"/"getExtensionStatus".
  // args_json is a JSON array of that method's positional arguments, in the
  // exact shape WebStorePrivateBridge.handle(payload:contents:) expects.
  // Swift must respond via OrbitWebContentsRespondToExtensionRequest with the
  // same request_id exactly once, async, never before this call returns.
  void (*native_extension_request)(void* opaque,
                                   const char* request_id,
                                   const char* method,
                                   const char* args_json);

  // Inspector lost its DevToolsAgentHost unexpectedly (renderer gone, target
  // closed); Swift should tear the inspector surface down. Never fired for a
  // Swift-initiated teardown.
  void (*devtools_closed)(void* opaque);

  // A context-menu gesture inside the page; synchronous, fire-and-forget --
  // content:: proceeds regardless of what Swift presents. String fields are
  // UTF-8, empty when Chromium has none. media_type: 0=none 1=image 2=video
  // 3=audio 4=canvas 5=file 6=plugin. x/y are the view's own coords
  // (top-left origin, DIPs).
  void (*show_context_menu)(void* opaque,
                            const char* page_url,
                            const char* frame_url,
                            const char* link_url,
                            const char* unfiltered_link_url,
                            const char* src_url,
                            const char* title_text,
                            const char* selection_text,
                            int media_type,
                            int is_editable,
                            const char* misspelled_word,
                            const char* dictionary_suggestions_json,
                            int x,
                            int y);

  // Tab entered/left video PiP, fired the moment content:: commits to the
  // transition rather than on a script poll. Also fired with 0 when the
  // floating window is torn down by navigation or the tab closing.
  void (*picture_in_picture_changed)(void* opaque, int is_active);

  // Page favicon from Blink's own candidate list (catches script-added
  // icons and data: URL hrefs a markup re-fetch would miss). icon_url may
  // be a data: URL (treat as identity, not a re-fetchable address); rgba is
  // `height` rows of `stride` bytes, premultiplied RGBA, valid only for the
  // duration of this call; null (dims 0) when download/decode produced
  // nothing.
  void (*favicon_changed)(void* opaque,
                          const char* icon_url,
                          const uint8_t* rgba,
                          int32_t width,
                          int32_t height,
                          int32_t stride);

  // Inspector docked (1) or undocked (0), from the frontend's own stored
  // preference. Nothing is on screen before the first of these; 1 means the
  // page draws on top of it at devtools_inspected_page_bounds' rect.
  void (*devtools_docked_changed)(void* opaque, int is_docked);

  // Where the page draws atop the docked frontend, in the frontend view's
  // own coords (top-left origin, DIPs); the dock side is implied by this
  // rect, never sent separately. `hide_inspected_page` 1 means device-mode
  // emulation is rendering the page itself instead.
  void (*devtools_inspected_page_bounds)(void* opaque,
                                         int x,
                                         int y,
                                         int width,
                                         int height,
                                         int hide_inspected_page);

  // The inspector's own close button. Swift should tear it down exactly as
  // OrbitWebContentsCloseDevTools plus destroying the frontend handle would.
  void (*devtools_close_requested)(void* opaque);

  // The frontend asked to be raised -- a debugger pause, a Reveal in
  // Elements. Swift should make whichever surface hosts the inspector key.
  void (*devtools_bring_to_front)(void* opaque);
} OrbitWebContentsCallbacks;

// NULL if the browser has not reached the ready callback yet. Owns a
// content::WebContents until OrbitWebContentsDestroy is called exactly once.
__attribute__((visibility("default")))
OrbitWebContentsHandle OrbitWebContentsCreate(void);

__attribute__((visibility("default")))
void OrbitWebContentsDestroy(OrbitWebContentsHandle handle);

// By pointer, not value: crosses into Swift via a dlsym'd function pointer,
// and a large-struct-by-value ABI call isn't worth relying on. Copied
// internally; the pointer need not outlive the call.
__attribute__((visibility("default")))
void OrbitWebContentsSetCallbacks(OrbitWebContentsHandle handle,
                                  const OrbitWebContentsCallbacks* callbacks);

// The WebContents' NSView*, untyped (Swift recovers via
// Unmanaged<NSView>.fromOpaque). Owned by the content::WebContents, not the
// caller -- add/remove as a subview, never release it.
__attribute__((visibility("default")))
void* OrbitWebContentsGetNativeView(OrbitWebContentsHandle handle);

// 1 when the native view is in an on-screen pane, 0 when not. content::
// otherwise infers this from AppKit alone, and gets it wrong for a view
// adopted into a container that is not in a window yet.
__attribute__((visibility("default")))
void OrbitWebContentsSetVisible(OrbitWebContentsHandle handle, int visible);

__attribute__((visibility("default")))
void OrbitWebContentsLoadURL(OrbitWebContentsHandle handle, const char* url);

__attribute__((visibility("default")))
void OrbitWebContentsReload(OrbitWebContentsHandle handle, int bypass_cache);

__attribute__((visibility("default")))
void OrbitWebContentsStop(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
void OrbitWebContentsGoBack(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
void OrbitWebContentsGoForward(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
void OrbitWebContentsGoToOffset(OrbitWebContentsHandle handle, int offset);

__attribute__((visibility("default")))
int OrbitWebContentsCanGoBack(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
int OrbitWebContentsCanGoForward(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
void OrbitWebContentsFocus(OrbitWebContentsHandle handle);

// content::WebContents::Cut/Copy/Paste/SelectAll. document.execCommand
// ('paste') is blocked by Blink for script-triggered paste, so this is the
// only real Paste path. No-op if the focused frame is not editable/has no
// selection.
__attribute__((visibility("default")))
void OrbitWebContentsCut(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
void OrbitWebContentsCopy(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
void OrbitWebContentsPaste(OrbitWebContentsHandle handle);

__attribute__((visibility("default")))
void OrbitWebContentsSelectAll(OrbitWebContentsHandle handle);

// success 0/1. On success result_json is JSON (Swift parses with
// JSONSerialization); on failure it is empty and error_message explains
// why. Called exactly once, possibly synchronously before this returns.
typedef void (*OrbitJavaScriptResultCallback)(void* opaque,
                                              int success,
                                              const char* result_json,
                                              const char* error_message);

// world: 0 runs in the main world (same world page script and document-start
// user scripts run in); any other value runs in Orbit's own isolated world,
// invisible to and unshadowable by the page.
__attribute__((visibility("default")))
void OrbitWebContentsEvaluateJavaScript(OrbitWebContentsHandle handle,
                                        const char* script,
                                        int world,
                                        OrbitJavaScriptResultCallback callback,
                                        void* callback_opaque);

// As above, but under a faked transient user activation, for live test
// suites reaching APIs that need a real gesture (chrome.permissions.request)
// without real input. Production code never fakes activation.
__attribute__((visibility("default")))
void OrbitWebContentsEvaluateJavaScriptWithUserGesture(
    OrbitWebContentsHandle handle,
    const char* script,
    int world,
    OrbitJavaScriptResultCallback callback,
    void* callback_opaque);

// One JSON-encoded UserScript (Orbit/Engine/EngineTypes.swift's Codable
// shape), upserted by id into this tab only, on top of the global list set
// by OrbitSetUserScripts. Mirrors WebContents.injectUserScript(_:).
__attribute__((visibility("default")))
void OrbitWebContentsInjectUserScript(OrbitWebContentsHandle handle,
                                      const char* user_script_json);

// JSON array of {"id":int,"url":string,"title":string,"offset":int}, one
// per back/forward entry, controller order (current entry has offset 0).
// Valid only until the next call on this handle -- copy it out immediately.
__attribute__((visibility("default")))
const char* OrbitWebContentsSessionHistory(OrbitWebContentsHandle handle);

// Loads `html` with `base_url` ("" for none) as its resolution base for
// relative URLs and same-origin checks. Never renderer-initiated, never in
// the back/forward list's "new tab" sense.
__attribute__((visibility("default")))
void OrbitWebContentsLoadHTML(OrbitWebContentsHandle handle,
                              const char* html,
                              const char* base_url);

// Saves the page as one self-contained MHTML file at `target_path` (parent
// directory must already exist). Fire-and-forget: SavePage's own return only
// reports whether the save started, never whether it finished.
__attribute__((visibility("default")))
void OrbitWebContentsSavePage(OrbitWebContentsHandle handle, const char* target_path);

// success 0/1, called exactly once, async, once the document is printed to
// a single PDF at `target_path` (parent directory must exist), via
// components/printing/browser/print_to_pdf. US Letter, ~10mm margins, no
// header/footer, scale 1.0 -- no print-preview UI to choose otherwise yet.
typedef void (*OrbitPrintToPdfCallback)(void* opaque, int success);
__attribute__((visibility("default")))
void OrbitWebContentsPrintToPdf(OrbitWebContentsHandle handle,
                                const char* target_path,
                                OrbitPrintToPdfCallback callback,
                                void* callback_opaque);

// Find in page; results reported through find_result_changed. find_next 0
// starts a new session; nonzero moves to the next/previous match.
__attribute__((visibility("default")))
void OrbitWebContentsFind(OrbitWebContentsHandle handle,
                          const char* text,
                          int forward,
                          int match_case,
                          int find_next);

// action: 0 clears the selection, 1 keeps it, 2 activates it -- mirrors
// blink::mojom::StopFindAction.
__attribute__((visibility("default")))
void OrbitWebContentsStopFinding(OrbitWebContentsHandle handle, int action);

// Auto-resize mode: the renderer lays the document out at its own preferred
// size within [min, max] DIPs, reported via preferred_size_changed; also
// pins zoom to neutral so the reported size isn't skewed. Reapplied to every
// later primary main frame. No-op if either max dimension is zero.
__attribute__((visibility("default")))
void OrbitWebContentsEnableAutoResize(OrbitWebContentsHandle handle,
                                      double min_width,
                                      double min_height,
                                      double max_width,
                                      double max_height);

// content::HostZoomMap::SetZoomLevel. Zoom is per-host, not per-tab, so this
// can affect (and fire zoom_factor_changed for) every other tab on the same host.
__attribute__((visibility("default")))
void OrbitWebContentsSetZoomFactor(OrbitWebContentsHandle handle, double factor);

// Enters/leaves PiP for this tab's live video player. Returns 1 if a player
// was found (not that a window appeared -- the page may still refuse). Uses
// the page's own requestPictureInPicture(), not
// MediaSession::EnterPictureInPicture, which registers no player for video
// that has never played unmuted. The actual transition is reported via
// picture_in_picture_changed, not this return value.
__attribute__((visibility("default")))
int OrbitWebContentsTogglePictureInPicture(OrbitWebContentsHandle handle);

// 1 if this tab currently has a video in Picture-in-Picture --
// content::WebContents::HasPictureInPictureVideo.
__attribute__((visibility("default")))
int OrbitWebContentsHasPictureInPictureVideo(OrbitWebContentsHandle handle);

// success 0/1. On success rgba_data is `height` rows of `stride` bytes,
// premultiplied RGBA (matches the compositor surface); on failure it is
// NULL and dims are 0. Called exactly once, async, on the UI thread; valid
// only for the duration of the call -- copy it out before returning.
typedef void (*OrbitCapturePreviewCallback)(void* opaque,
                                            int success,
                                            const uint8_t* rgba_data,
                                            int32_t width,
                                            int32_t height,
                                            int32_t stride);

// has_rect 0 captures the whole surface; target dims 0/0 means native
// resolution. Plain params, not a struct: mixed int/double fields have
// compiler-decided padding Swift can't guarantee to mirror byte-for-byte.
__attribute__((visibility("default")))
void OrbitWebContentsCapturePreview(OrbitWebContentsHandle handle,
                                    int has_rect,
                                    double rect_x,
                                    double rect_y,
                                    double rect_width,
                                    double rect_height,
                                    double target_width,
                                    double target_height,
                                    OrbitCapturePreviewCallback callback,
                                    void* callback_opaque);

// Opens DevTools for `handle`, returning a new handle the caller must call
// OrbitWebContentsDestroy exactly once, as with OrbitWebContentsCreate
// (destroying it closes the inspector). has_inspect_point/inspect_x/
// inspect_y select the element under a right-click, in the inspected view's
// own coordinates, and are ignored when has_inspect_point is 0. Must not be
// presented until devtools_docked_changed says where it belongs. NULL if
// `handle` already has an open inspector or the browser is not ready.
__attribute__((visibility("default")))
OrbitWebContentsHandle OrbitWebContentsOpenDevTools(OrbitWebContentsHandle handle,
                                                    int has_inspect_point,
                                                    int inspect_x,
                                                    int inspect_y);

// The frontend handle of `handle`'s open inspector, or NULL if none is open.
// Not a second reference to own -- OrbitWebContentsOpenDevTools' caller still
// owns destroying it.
__attribute__((visibility("default")))
OrbitWebContentsHandle OrbitWebContentsDevToolsFrontend(OrbitWebContentsHandle handle);

// Detaches the inspector's CDP client from `handle` immediately, so the page
// stops being debugged. The frontend handle stays valid and must still be
// destroyed by its owner. A no-op if no inspector is open.
__attribute__((visibility("default")))
void OrbitWebContentsCloseDevTools(OrbitWebContentsHandle handle);

// Re-points an already-open inspector at the element under (x, y) of the
// inspected view. A no-op if no inspector is open.
__attribute__((visibility("default")))
void OrbitWebContentsInspectElementAt(OrbitWebContentsHandle handle, int x, int y);

// JSON {"open":bool} plus, when open, {"attached":bool,"frontendURL":string,
// "commandsFromFrontend":int,"responsesToFrontend":int,"eventsToFrontend":int,
// "dockDecided":bool,"docked":bool,"dockSide":string,
// "hidesInspectedPage":bool,"inspectedPageBounds":{x,y,width,height}}.
// "dockSide" is the frontend's own persisted preference, PROCESS-GLOBAL (not
// per-tab) and surviving restarts; the counters are over the CDP pipe, so a
// non-zero responsesToFrontend proves the protocol is answering. Returned
// pointer is a process-global buffer, overwritten by the next call.
__attribute__((visibility("default")))
const char* OrbitWebContentsDevToolsStateJSON(OrbitWebContentsHandle handle);

// Effective appearance (non-zero dark, 0 light), process-global; this is
// what blink's prefers-color-scheme answers, permanently "light" until
// called. Re-themes every open document in place; does not touch DevTools'
// own stored theme preference.
__attribute__((visibility("default")))
void OrbitSetColorSchemeIsDark(int is_dark);

// Replaces the whole global UserScript list (JSON array), mirroring
// BrowserEngine.addUserScript/removeUserScript. Applies to every open tab,
// present and future.
__attribute__((visibility("default")))
void OrbitSetUserScripts(const char* user_scripts_json);

// Process-wide default UA (content:: has no per-BrowserContext UA). ""
// restores content::ContentBrowserClient::GetUserAgent()'s default. Only
// affects a frame's next navigation, never an already-loaded document.
__attribute__((visibility("default")))
void OrbitSetUserAgent(const char* user_agent);

// JSON array of {"name":string,"value":string,"domain":string,"path":string,
// "secure":bool,"httpOnly":bool,"sameSite":string ("unspecified"/"none"/
// "lax"/"strict"),"expiresAt":number-or-null (seconds since 1970),
// "createdAt":number,"lastAccessedAt":number}. `callback` exactly once,
// async, on the UI thread; "[]" (never NULL) if no BrowserContext yet or the
// fetch fails.
typedef void (*OrbitCookiesCallback)(void* opaque, const char* cookies_json);
__attribute__((visibility("default")))
void OrbitGetCookies(const char* url, OrbitCookiesCallback callback, void* callback_opaque);

// Deletes every cookie CookieDeletionFilter's URL-matching rules select for
// `url`. `callback` exactly once, async, on the UI thread.
typedef void (*OrbitCompletionCallback)(void* opaque);
__attribute__((visibility("default")))
void OrbitDeleteCookies(const char* url, OrbitCompletionCallback callback, void* callback_opaque);

// `cookies_json` matches OrbitCookiesCallback's shape. Invalid entries are
// skipped, never fabricated as accepted. `callback` exactly once, async,
// with the accepted count.
typedef void (*OrbitSetCookiesCallback)(void* opaque, int32_t accepted_count);
__attribute__((visibility("default")))
void OrbitSetCookies(const char* cookies_json, OrbitSetCookiesCallback callback, void* callback_opaque);

// Asked once per intercepted network request, on a background sequence
// (base::ThreadPool), never the UI thread -- the match is lock-free and too
// expensive to serialize there. request_url/document_url are UTF-8, never
// null (document_url is "" when there is no meaningful top-level document,
// e.g. a service worker's own subresource fetch). resource_type mirrors
// ContentBlockingResourceType; do not renumber independently. Never called
// (request always allowed) before this is registered. Returns 0=allow
// 1=block (ERR_BLOCKED_BY_CLIENT) 2=substitute, which alone writes
// *out_mime_type (NUL-terminated UTF-8) and *out_body (NULL iff
// *out_body_length is 0) as malloc()'d buffers the caller must free().
typedef int (*OrbitContentBlockingDecisionCallback)(void* opaque,
                                                     const char* request_url,
                                                     const char* document_url,
                                                     int resource_type,
                                                     char** out_mime_type,
                                                     uint8_t** out_body,
                                                     int32_t* out_body_length);
__attribute__((visibility("default")))
void OrbitSetContentBlockingDecisionCallback(
    OrbitContentBlockingDecisionCallback callback, void* opaque);

// True once a real, enabled ContentBlocker is active; false initially and
// after clearing. WillCreateURLLoaderFactory reads this to skip inserting
// the interceptor entirely when false, not merely always-allow it.
__attribute__((visibility("default")))
void OrbitSetContentBlockingActive(int active);

// Loads the unpacked extension at directory_path (into every renderer too,
// if activation is .immediate). `callback` exactly once, async, never before
// this returns; success 0/1, extension_json matches one
// OrbitGetLoadedExtensionsJSON element. Requires the ready callback to have
// already fired.
typedef void (*OrbitLoadExtensionCallback)(void* opaque,
                                           int success,
                                           const char* extension_json,
                                           const char* error_message);
__attribute__((visibility("default")))
void OrbitLoadExtension(const char* directory_path,
                        OrbitLoadExtensionCallback callback,
                        void* callback_opaque);

// OrbitLoadExtension for the boot-time restore pass: chrome.runtime.onStartup
// fires here (nowhere else does), and a matching on-disk version
// re-registers rather than reinstalls, so onInstalled does NOT fire and
// persisted service-worker registrations survive the restart.
__attribute__((visibility("default")))
void OrbitLoadExtensionForStartup(const char* directory_path,
                                  OrbitLoadExtensionCallback callback,
                                  void* callback_opaque);

// Removes extension_id for the rest of this run, keeping its stored state
// (esp. runtime-granted permissions) so reloading resumes where it left off.
// Does not delete its source directory. No-op if not currently loaded.
__attribute__((visibility("default")))
void OrbitUnloadExtension(const char* extension_id);

// OrbitUnloadExtension, and forgets what the extension stored: the call for a
// user actually removing it, after which a later install of the same id
// starts from nothing rather than inheriting the old grants.
__attribute__((visibility("default")))
void OrbitUninstallExtension(const char* extension_id);

// JSON array of every loaded extension (enabled or disabled), shaped like
// OrbitLoadExtensionCallback's extension_json. Never null; "[]" if none loaded.
__attribute__((visibility("default")))
const char* OrbitGetLoadedExtensionsJSON(void);

// No-op if download_id isn't currently tracked. Cancel/pause/resume operate
// on the download itself, not the tab, so unlike everything above these
// take no OrbitWebContentsHandle.
__attribute__((visibility("default")))
void OrbitCancelDownload(const char* download_id);

__attribute__((visibility("default")))
void OrbitPauseDownload(const char* download_id);

__attribute__((visibility("default")))
void OrbitResumeDownload(const char* download_id);

// Returns "ask" (never answered), "allow", "block", or "unsupported" (bad
// scheme or kind) for (kind, url's origin). Never null. Reads the same
// OrbitPermissionStore a live allowAlways/denyAlways answer writes.
__attribute__((visibility("default")))
const char* OrbitGetContentSetting(const char* kind, const char* url);

// `setting` is one of "ask" (clears any stored decision for this (kind, url)
// origin), "allow", or "block"; anything else, or a `kind`/`url` that
// OrbitGetContentSetting would call "unsupported", is a no-op.
__attribute__((visibility("default")))
void OrbitSetContentSetting(const char* setting, const char* kind, const char* url);

// chrome.tabs/windows bridge (backs OrbitTabRegistry). Swift pushes its own
// definitive tab/window state via the OrbitTabs*/OrbitWindows* calls below;
// every function is UI-thread-only and synchronous.
//
// Assigns tab_id (small positive, allocated once, never reused) to handle's
// tab. Call exactly once per real user-visible tab, before any other
// OrbitTabs* call names it -- never for a popup/options page. Fires
// tabs.onCreated.
__attribute__((visibility("default")))
void OrbitTabsCreated(OrbitWebContentsHandle handle,
                      int32_t tab_id,
                      int32_t window_id,
                      int32_t index,
                      int active,
                      int pinned);

// Fires tabs.onRemoved and forgets tab_id. Must be called before
// OrbitWebContentsDestroy on the same handle -- once destroyed there is no
// way to read title/url from it for the event or any later query.
__attribute__((visibility("default")))
void OrbitTabsRemoved(int32_t tab_id, int window_closing);

// Fires tabs.onActivated(tabId, windowId). previous_tab_id 0 if none (e.g.
// the first tab in a newly created window).
__attribute__((visibility("default")))
void OrbitTabsActivated(int32_t tab_id, int32_t window_id, int32_t previous_tab_id);

// Fires tabs.onMoved(tabId, {windowId, fromIndex, toIndex}). No-op, no
// event, if from_index equals to_index.
__attribute__((visibility("default")))
void OrbitTabsMoved(int32_t tab_id, int32_t window_id, int32_t from_index, int32_t to_index);

// Updates the pinned bit and fires tabs.onUpdated with changeInfo {pinned}
// if it actually changed.
__attribute__((visibility("default")))
void OrbitTabsSetPinned(int32_t tab_id, int pinned);

// Sets the tab's position, firing nothing -- Chrome fires no event for a
// displaced tab, only changes its reported index. Swift pushes one call per
// tab after every ordering change.
__attribute__((visibility("default")))
void OrbitTabsIndexChanged(int32_t tab_id, int32_t index);

// Registers window_id, fires windows.onCreated. If focused, also fires
// windows.onFocusChanged the same as OrbitWindowsFocusChanged would.
__attribute__((visibility("default")))
void OrbitWindowsCreated(int32_t window_id, int focused);

// Fires windows.onRemoved and forgets window_id.
__attribute__((visibility("default")))
void OrbitWindowsRemoved(int32_t window_id);

// window_id 0 means every Orbit window lost focus, matching
// windows.WINDOW_ID_NONE's -1 at the JS layer; OrbitTabRegistry does the
// -1-vs-0 translation (0 is never a real Orbit-assigned id).
__attribute__((visibility("default")))
void OrbitWindowsFocusChanged(int32_t window_id);

// `state` is windows.json's WindowState value ("normal"/"minimized"/
// "maximized"/"fullscreen"), read from the real NSWindow. Fires nothing:
// chrome.windows has no state-changed event in this subset.
__attribute__((visibility("default")))
void OrbitWindowsStateChanged(int32_t window_id, const char* state);

// Delegate an extension's tabs.create/update/remove call reaches. Every
// function returns 0/1; on create_tab success, OrbitTabsCreated has already
// been called for the new tab by the time it returns.
typedef struct {
  void* opaque;
  int (*create_tab)(void* opaque,
                    int32_t window_id,
                    const char* url,
                    int active,
                    int pinned,
                    OrbitWebContentsHandle* out_web_contents,
                    int32_t* out_tab_id);
  int (*update_tab_url)(void* opaque, int32_t tab_id, const char* url);
  int (*activate_tab)(void* opaque, int32_t tab_id);
  int (*remove_tab)(void* opaque, int32_t tab_id);
  int (*set_tab_pinned)(void* opaque, int32_t tab_id, int pinned);
} OrbitTabsDelegate;

// Replaces any previously-installed delegate; NULL clears it (every
// extension-initiated tabs.create/update/remove/activate call then fails
// with an error, same as before this is ever called).
__attribute__((visibility("default")))
void OrbitSetTabsDelegate(const OrbitTabsDelegate* delegate);

// Fired per extensions::ExtensionHostDelegate::CreateTab (window.open() etc;
// content:: has already built the WebContents). disposition mirrors
// WindowOpenDisposition (0=unknown 1=currentTab 2=singletonTab
// 3=newForegroundTab 4=newBackgroundTab 5=newPopup 6=newWindow 7=saveToDisk
// 8=offTheRecord 9=ignoreAction 10=switchToTab 11=newPictureInPicture).
// Returns 1 if adopted (must call OrbitTabsCreated first); 0 to decline
// (caller destroys `handle`).
typedef int (*OrbitExtensionTabRequestCallback)(void* opaque,
                                                 OrbitWebContentsHandle handle,
                                                 const char* url,
                                                 const char* extension_id,
                                                 int disposition,
                                                 int user_gesture);
__attribute__((visibility("default")))
void OrbitSetExtensionTabRequestCallback(
    OrbitExtensionTabRequestCallback callback, void* opaque);

// Every page-initiated request to put content in a new tab (target="_blank",
// window.open(), Cmd/middle-click, "open in new tab"). Without a callback
// registered, content:: destroys the pending WebContents -- the browser
// silently refusing the link. `source` is never null. `handle` is non-null
// only when content:: has already built the WebContents (must adopt via
// OrbitTabsCreated before returning 1); null means Swift should open a
// fresh tab at `url` itself. `url` is UTF-8, never null (empty only for an
// about:blank window.open()). disposition adds 12=newSplitView to
// OrbitSetExtensionTabRequestCallback's list.
typedef int (*OrbitNewContentRequestCallback)(void* opaque,
                                              OrbitWebContentsHandle source,
                                              OrbitWebContentsHandle handle,
                                              const char* url,
                                              int disposition,
                                              int user_gesture);
__attribute__((visibility("default")))
void OrbitSetNewContentRequestCallback(
    OrbitNewContentRequestCallback callback, void* opaque);

// Delivers one native_extension_request answer, in WebStorePrivateBridge.
// encode(_:)'s {"ok":...} envelope. Exactly once per request_id; unknown or
// already-answered is a no-op.
__attribute__((visibility("default")))
void OrbitWebContentsRespondToExtensionRequest(OrbitWebContentsHandle handle,
                                               const char* request_id,
                                               const char* result_json);

// chrome.management enable/disable/uninstall; Orbit's ExtensionStore owns
// the on-disk record. confirm_uninstall must answer exactly once via
// OrbitManagementUninstallConsent; unanswered stays refused.
typedef struct {
  void* opaque;
  int (*set_enabled)(void* opaque, const char* extension_id, int enabled);
  void (*confirm_uninstall)(void* opaque, const char* extension_id,
                            uint64_t request_id);
  // Only ever called after confirm_uninstall was answered with 1.
  int (*uninstall)(void* opaque, const char* extension_id);
} OrbitManagementDelegate;

// Replaces any previously-installed delegate; NULL clears it, after which
// every chrome.management enable/disable/uninstall fails rather than
// silently succeeding.
__attribute__((visibility("default")))
void OrbitSetManagementDelegate(const OrbitManagementDelegate* delegate);

// The user's answer to one confirm_uninstall. Unknown or already-answered
// request_id is a no-op.
__attribute__((visibility("default")))
void OrbitManagementUninstallConsent(uint64_t request_id, int approved);

// chrome.permissions.request consent: {"extensionId":string,
// "extensionName":string,"permissions":[string,...],"origins":[string,...],
// "warnings":[string,...]} -- only the manifest-declared optional grants
// actually asked for; warnings always non-empty (a no-warning request is
// auto-granted). request_consent must answer exactly once via
// OrbitPermissionsConsentResponse; unanswered stays refused.
typedef struct {
  void* opaque;
  void (*request_consent)(void* opaque, const char* request_json,
                          uint64_t request_id);
} OrbitPermissionsConsentDelegate;

// NULL clears the delegate; every prompt-needing request then fails rather
// than silently granting. Any outstanding request is answered "refused" first.
__attribute__((visibility("default")))
void OrbitSetPermissionsConsentDelegate(
    const OrbitPermissionsConsentDelegate* delegate);

// The user's answer to one request_consent. Unknown or already-answered
// request_id is a no-op.
__attribute__((visibility("default")))
void OrbitPermissionsConsentResponse(uint64_t request_id, int approved);

// chrome.action state, fired once per mutation and once per extension
// load/unload, on the UI thread: {"extensionId":string,"defaults":{...},
// "tabs":[{"tabId":int,...}]}. Each state object carries "badgeText",
// "badgeBackgroundColor"/"badgeTextColor" ("#RRGGBBAA"), "title",
// "isEnabled", "popupUrl", "iconPNG" (base64, only when set). `defaults` is
// what every tab sees; `tabs` carries only tabs with a value of their own.
typedef void (*OrbitExtensionActionCallback)(void* opaque,
                                             const char* action_json);
__attribute__((visibility("default")))
void OrbitSetExtensionActionCallback(OrbitExtensionActionCallback callback,
                                     void* opaque);

// JSON array of one ExtensionActionCallback payload per extension declaring
// an action. Never null; "[]" if not ready. Read once at ready so an early
// badge isn't lost.
__attribute__((visibility("default")))
const char* OrbitGetExtensionActionsJSON(void);

// One primary-main-frame certificate error (subresource/subframe/prerender/
// fenced-frame errors are denied outright, never reaching here). Swift must
// call OrbitWebContentsRespondToCertificateError with the same request_id
// exactly once, async; no response, or no callback registered, denies the
// navigation. overridable 0 means Swift must not offer to proceed -- an
// "allow" is refused server-side regardless.
//
// request_url/host/issuer/subject/error_name are UTF-8, never null (empty
// when the certificate has no such field); issuer/subject are
// CertPrincipal::GetDisplayName() (CN else O else OU). cert_error is always
// negative and always one net::IsCertificateError accepts; error_name is its
// ErrorToShortString spelling. valid_from/valid_until are SECONDS SINCE 1970,
// 0 when the certificate states no such date. request_id is unique within
// `handle`, never reused.
typedef void (*OrbitCertificateErrorCallback)(void* opaque,
                                              OrbitWebContentsHandle handle,
                                              uint64_t request_id,
                                              const char* request_url,
                                              const char* host,
                                              int cert_error,
                                              const char* error_name,
                                              const char* issuer,
                                              const char* subject,
                                              double valid_from,
                                              double valid_until,
                                              int overridable);

// Replaces any previously-installed callback; NULL clears it, after which
// every certificate error is denied without ever being shown.
__attribute__((visibility("default")))
void OrbitSetCertificateErrorCallback(OrbitCertificateErrorCallback callback,
                                      void* opaque);

// A nonzero `allow` on an overridable request continues navigation and
// records an in-memory-only exception (host, cert fingerprint, error) for
// this run; never written to disk. Anything else denies the navigation.
// Must only be called with an explicit user action behind it.
__attribute__((visibility("default")))
void OrbitWebContentsRespondToCertificateError(OrbitWebContentsHandle handle,
                                               uint64_t request_id,
                                               int allow);

// chrome.privacy.services.searchSuggestEnabled, the same setting the
// Profile toggle in Settings owns. Fires whenever the EFFECTIVE value
// changes, from an extension's ChromeSetting.set or the setter below.
typedef void (*OrbitSearchSuggestEnabledCallback)(void* opaque, int enabled);
__attribute__((visibility("default")))
void OrbitSetSearchSuggestEnabledCallback(
    OrbitSearchSuggestEnabledCallback callback,
    void* opaque);

// The effective value: an extension override if one is in force, otherwise
// the user value. Nonzero for enabled. 0 if the browser is not ready.
__attribute__((visibility("default")))
int OrbitGetSearchSuggestEnabled(void);

// Writes the USER value; an extension override still takes precedence, so
// this can change the stored value without changing the effective one (the
// callback above reports what took effect).
__attribute__((visibility("default")))
void OrbitSetSearchSuggestEnabled(int enabled);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // ORBIT_EMBEDDER_BRIDGE_ORBIT_BRIDGE_API_H_
