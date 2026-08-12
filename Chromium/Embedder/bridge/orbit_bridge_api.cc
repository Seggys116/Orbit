// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_bridge_api.h"

#include <atomic>
#include <cstdlib>
#include <map>
#include <optional>
#include <string>
#include <string_view>
#include <utility>

#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/dcheck_is_on.h"
#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/no_destructor.h"
#include "base/version_info/version_info.h"
#include "content/public/browser/native_event_processor_observer_mac.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_browser_context.h"
#include "orbit/browser/orbit_color_scheme.h"
#include "orbit/browser/orbit_cookie_bridge.h"
#include "orbit/browser/orbit_devtools_frontend.h"
#include "orbit/browser/orbit_download_bridge.h"
#include "orbit/browser/orbit_extension_action_dispatcher.h"
#include "orbit/browser/orbit_preference_event_router.h"
#include "orbit/browser/orbit_extension_loader.h"
#include "orbit/browser/orbit_permission_store.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "orbit/browser/orbit_user_script_registry.h"
#include "orbit/browser/orbit_web_contents_host.h"
#include "orbit/common/orbit_user_data_dir.h"
#include "orbit/common/orbit_user_script_spec.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace orbit {

namespace {

OrbitBrowserContext* g_browser_context = nullptr;
OrbitBrowserReadyCallback g_ready_callback = nullptr;
void* g_ready_opaque = nullptr;

OrbitContentBlockingDecisionCallback g_content_blocking_decision_callback = nullptr;
void* g_content_blocking_decision_opaque = nullptr;

OrbitExtensionTabRequestCallback g_extension_tab_request_callback = nullptr;
void* g_extension_tab_request_opaque = nullptr;

OrbitNewContentRequestCallback g_new_content_request_callback = nullptr;
void* g_new_content_request_opaque = nullptr;

OrbitCertificateErrorCallback g_certificate_error_callback = nullptr;
void* g_certificate_error_opaque = nullptr;

// UI-thread-only on both read and write; atomic so a future threading
// change on either side doesn't need re-auditing.
std::atomic<bool> g_content_blocking_active{false};

base::OnceClosure& QuitClosureStorage() {
  static base::NoDestructor<base::OnceClosure> storage;
  return *storage;
}

OrbitWebContentsHost* ToHost(OrbitWebContentsHandle handle) {
  return reinterpret_cast<OrbitWebContentsHost*>(handle);
}

}  // namespace

void NotifyOrbitBrowserReady(OrbitBrowserContext* browser_context) {
  g_browser_context = browser_context;
  if (g_ready_callback) {
    g_ready_callback(g_ready_opaque);
  }
}

void SetOrbitBrowserQuitClosure(base::OnceClosure quit_closure) {
  QuitClosureStorage() = std::move(quit_closure);
}

void ClearOrbitBrowserState() {
  g_browser_context = nullptr;
  QuitClosureStorage() = base::OnceClosure();
}

ContentBlockingRequestDecision DecideContentBlocking(
    const std::string& request_url,
    const std::string& document_url,
    int resource_type) {
  ContentBlockingRequestDecision decision;
  if (!g_content_blocking_decision_callback) {
    return decision;
  }

  char* mime_type = nullptr;
  uint8_t* body = nullptr;
  int32_t body_length = 0;
  const int kind = g_content_blocking_decision_callback(
      g_content_blocking_decision_opaque, request_url.c_str(),
      document_url.c_str(), resource_type, &mime_type, &body, &body_length);

  if (mime_type) {
    decision.mime_type.assign(mime_type);
    free(mime_type);
  }
  if (body) {
    if (body_length > 0) {
      // SAFETY: the callback's contract is that `body` points to exactly
      // `body_length` bytes -- see OrbitContentBlockingDecisionCallback.
      auto bytes = UNSAFE_BUFFERS(
          base::span(body, static_cast<size_t>(body_length)));
      decision.body.assign(bytes.begin(), bytes.end());
    }
    free(body);
  }

  switch (kind) {
    case 1:
      decision.kind = ContentBlockingRequestDecision::Kind::kBlock;
      break;
    case 2:
      // A substitution with no MIME type cannot be served as anything
      // definite, and guessing would let the response be sniffed into
      // whatever the document wanted; fail it closed instead.
      decision.kind = decision.mime_type.empty()
                          ? ContentBlockingRequestDecision::Kind::kBlock
                          : ContentBlockingRequestDecision::Kind::kSubstitute;
      break;
    default:
      break;
  }

  if (decision.kind != ContentBlockingRequestDecision::Kind::kSubstitute) {
    decision.mime_type.clear();
    decision.body.clear();
  }
  return decision;
}

content::BrowserContext* GetOrbitBrowserContext() {
  return g_browser_context;
}

bool IsContentBlockingActive() {
  return g_content_blocking_active.load(std::memory_order_relaxed);
}

bool RequestExtensionTab(OrbitWebContentsHost* host,
                         const std::string& url,
                         const std::string& extension_id,
                         int disposition,
                         bool user_gesture) {
  if (!g_extension_tab_request_callback) {
    return false;
  }
  return g_extension_tab_request_callback(
             g_extension_tab_request_opaque,
             reinterpret_cast<OrbitWebContentsHandle>(host), url.c_str(),
             extension_id.c_str(), disposition, user_gesture ? 1 : 0) != 0;
}

bool RequestNewContent(OrbitWebContentsHost* source,
                       OrbitWebContentsHost* host,
                       const std::string& url,
                       int disposition,
                       bool user_gesture) {
  if (!g_new_content_request_callback || !source) {
    return false;
  }
  return g_new_content_request_callback(
             g_new_content_request_opaque,
             reinterpret_cast<OrbitWebContentsHandle>(source),
             reinterpret_cast<OrbitWebContentsHandle>(host), url.c_str(),
             disposition, user_gesture ? 1 : 0) != 0;
}

bool DispatchCertificateError(OrbitWebContentsHost* host,
                              uint64_t request_id,
                              const CertificateErrorReport& report) {
  if (!g_certificate_error_callback || !host) {
    return false;
  }
  g_certificate_error_callback(
      g_certificate_error_opaque,
      reinterpret_cast<OrbitWebContentsHandle>(host), request_id,
      report.request_url.c_str(), report.host.c_str(), report.cert_error,
      report.error_name.c_str(), report.issuer.c_str(), report.subject.c_str(),
      report.valid_from, report.valid_until, report.overridable ? 1 : 0);
  return true;
}

}  // namespace orbit

void OrbitSetBrowserReadyCallback(OrbitBrowserReadyCallback callback,
                                  void* opaque) {
  orbit::g_ready_callback = callback;
  orbit::g_ready_opaque = opaque;
}

void OrbitNotifyWillRunNativeEvent(void* observer, uintptr_t identifier) {
  if (!observer) {
    return;
  }
  static_cast<content::NativeEventProcessorObserver*>(observer)
      ->WillRunNativeEvent(identifier);
}

void OrbitNotifyDidRunNativeEvent(void* observer, uintptr_t identifier) {
  if (!observer) {
    return;
  }
  static_cast<content::NativeEventProcessorObserver*>(observer)
      ->DidRunNativeEvent(identifier);
}

int OrbitRequestBrowserQuit(void) {
  base::OnceClosure& closure = orbit::QuitClosureStorage();
  if (closure.is_null()) {
    return 0;
  }
  std::move(closure).Run();
  return 1;
}

const char* OrbitChromiumVersionNumber(void) {
  static const std::string version(version_info::GetVersionNumber());
  return version.c_str();
}

const char* OrbitEngineBuildMarker(void) {
#if DCHECK_IS_ON()
  return "orbit-engine-build: dcheck=1";
#else
  return "orbit-engine-build: dcheck=0";
#endif
}

void OrbitSetUserDataDirectory(const char* path) {
  orbit::SetPendingOrbitUserDataDir(path ? std::string_view(path)
                                         : std::string_view());
}

const char* OrbitBrowserContextPath(void) {
  static base::NoDestructor<std::string> path;
  *path = orbit::g_browser_context ? orbit::g_browser_context->GetPath().value()
                                   : std::string();
  return path->c_str();
}

OrbitWebContentsHandle OrbitWebContentsCreate(void) {
  if (!orbit::g_browser_context) {
    return nullptr;
  }
  auto* host = new orbit::OrbitWebContentsHost(orbit::g_browser_context);
  return reinterpret_cast<OrbitWebContentsHandle>(host);
}

void OrbitWebContentsDestroy(OrbitWebContentsHandle handle) {
  delete orbit::ToHost(handle);
}

void OrbitWebContentsSetCallbacks(OrbitWebContentsHandle handle,
                                  const OrbitWebContentsCallbacks* callbacks) {
  if (!callbacks) {
    return;
  }
  orbit::ToHost(handle)->SetCallbacks(*callbacks);
}

void* OrbitWebContentsGetNativeView(OrbitWebContentsHandle handle) {
  return orbit::ToHost(handle)->GetNativeView();
}

void OrbitWebContentsSetVisible(OrbitWebContentsHandle handle, int visible) {
  orbit::ToHost(handle)->SetVisible(visible != 0);
}

void OrbitWebContentsLoadURL(OrbitWebContentsHandle handle, const char* url) {
  orbit::ToHost(handle)->LoadURL(url ? std::string(url) : std::string());
}

void OrbitWebContentsReload(OrbitWebContentsHandle handle, int bypass_cache) {
  orbit::ToHost(handle)->Reload(bypass_cache != 0);
}

void OrbitWebContentsStop(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->Stop();
}

void OrbitWebContentsGoBack(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->GoBack();
}

void OrbitWebContentsGoForward(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->GoForward();
}

void OrbitWebContentsGoToOffset(OrbitWebContentsHandle handle, int offset) {
  orbit::ToHost(handle)->GoToOffset(offset);
}

int OrbitWebContentsCanGoBack(OrbitWebContentsHandle handle) {
  return orbit::ToHost(handle)->CanGoBack() ? 1 : 0;
}

int OrbitWebContentsCanGoForward(OrbitWebContentsHandle handle) {
  return orbit::ToHost(handle)->CanGoForward() ? 1 : 0;
}

void OrbitWebContentsFocus(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->Focus();
}

void OrbitWebContentsCut(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->Cut();
}

void OrbitWebContentsCopy(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->Copy();
}

void OrbitWebContentsPaste(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->Paste();
}

void OrbitWebContentsSelectAll(OrbitWebContentsHandle handle) {
  orbit::ToHost(handle)->SelectAll();
}

void OrbitWebContentsEnableAutoResize(OrbitWebContentsHandle handle,
                                      double min_width,
                                      double min_height,
                                      double max_width,
                                      double max_height) {
  orbit::ToHost(handle)->EnableAutoResize(min_width, min_height, max_width,
                                          max_height);
}

void OrbitWebContentsEvaluateJavaScript(OrbitWebContentsHandle handle,
                                        const char* script,
                                        int world,
                                        OrbitJavaScriptResultCallback callback,
                                        void* callback_opaque) {
  orbit::ToHost(handle)->EvaluateJavaScript(
      script ? std::string(script) : std::string(), world,
      /*user_gesture=*/false, callback, callback_opaque);
}

void OrbitWebContentsEvaluateJavaScriptWithUserGesture(
    OrbitWebContentsHandle handle,
    const char* script,
    int world,
    OrbitJavaScriptResultCallback callback,
    void* callback_opaque) {
  orbit::ToHost(handle)->EvaluateJavaScript(
      script ? std::string(script) : std::string(), world,
      /*user_gesture=*/true, callback, callback_opaque);
}

void OrbitWebContentsInjectUserScript(OrbitWebContentsHandle handle,
                                      const char* user_script_json) {
  orbit::ToHost(handle)->AddLocalUserScript(
      user_script_json ? std::string(user_script_json) : std::string());
}

const char* OrbitWebContentsSessionHistory(OrbitWebContentsHandle handle) {
  return orbit::ToHost(handle)->SessionHistoryJSON();
}

void OrbitWebContentsLoadHTML(OrbitWebContentsHandle handle,
                              const char* html,
                              const char* base_url) {
  orbit::ToHost(handle)->LoadHTML(html ? std::string(html) : std::string(),
                                  base_url ? std::string(base_url) : std::string());
}

void OrbitWebContentsSavePage(OrbitWebContentsHandle handle, const char* target_path) {
  orbit::ToHost(handle)->SavePage(target_path ? std::string(target_path) : std::string());
}

void OrbitWebContentsPrintToPdf(OrbitWebContentsHandle handle,
                                const char* target_path,
                                OrbitPrintToPdfCallback callback,
                                void* callback_opaque) {
  orbit::ToHost(handle)->PrintToPdf(
      target_path ? std::string(target_path) : std::string(), callback, callback_opaque);
}

void OrbitWebContentsFind(OrbitWebContentsHandle handle,
                          const char* text,
                          int forward,
                          int match_case,
                          int find_next) {
  orbit::ToHost(handle)->Find(text ? std::string(text) : std::string(), forward != 0,
                              match_case != 0, find_next != 0);
}

void OrbitWebContentsStopFinding(OrbitWebContentsHandle handle, int action) {
  orbit::ToHost(handle)->StopFinding(action);
}

void OrbitWebContentsSetZoomFactor(OrbitWebContentsHandle handle, double factor) {
  orbit::ToHost(handle)->SetZoomFactor(factor);
}

int OrbitWebContentsTogglePictureInPicture(OrbitWebContentsHandle handle) {
  return orbit::ToHost(handle)->TogglePictureInPicture() ? 1 : 0;
}

int OrbitWebContentsHasPictureInPictureVideo(OrbitWebContentsHandle handle) {
  return orbit::ToHost(handle)->HasPictureInPictureVideo() ? 1 : 0;
}

void OrbitWebContentsCapturePreview(OrbitWebContentsHandle handle,
                                    int has_rect,
                                    double rect_x,
                                    double rect_y,
                                    double rect_width,
                                    double rect_height,
                                    double target_width,
                                    double target_height,
                                    OrbitCapturePreviewCallback callback,
                                    void* callback_opaque) {
  orbit::ToHost(handle)->CapturePreview(has_rect != 0, rect_x, rect_y, rect_width, rect_height,
                                        target_width, target_height, callback, callback_opaque);
}

OrbitWebContentsHandle OrbitWebContentsOpenDevTools(OrbitWebContentsHandle handle,
                                                    int has_inspect_point,
                                                    int inspect_x,
                                                    int inspect_y) {
  if (!handle) {
    return nullptr;
  }
  orbit::OrbitWebContentsHost* frontend = orbit::OpenDevToolsFor(
      orbit::ToHost(handle), has_inspect_point != 0, inspect_x, inspect_y);
  return reinterpret_cast<OrbitWebContentsHandle>(frontend);
}

OrbitWebContentsHandle OrbitWebContentsDevToolsFrontend(OrbitWebContentsHandle handle) {
  if (!handle) {
    return nullptr;
  }
  return reinterpret_cast<OrbitWebContentsHandle>(
      orbit::DevToolsFrontendFor(orbit::ToHost(handle)));
}

void OrbitWebContentsCloseDevTools(OrbitWebContentsHandle handle) {
  if (handle) {
    orbit::CloseDevToolsFor(orbit::ToHost(handle));
  }
}

void OrbitWebContentsInspectElementAt(OrbitWebContentsHandle handle, int x, int y) {
  if (handle) {
    orbit::InspectElementInDevTools(orbit::ToHost(handle), x, y);
  }
}

const char* OrbitWebContentsDevToolsStateJSON(OrbitWebContentsHandle handle) {
  static base::NoDestructor<std::string> buffer;
  *buffer = handle ? orbit::DevToolsStateJSONFor(orbit::ToHost(handle))
                   : std::string("{\"open\":false}");
  return buffer->c_str();
}

void OrbitSetColorSchemeIsDark(int is_dark) {
  orbit::SetColorSchemeIsDark(is_dark != 0);
}

void OrbitSetUserScripts(const char* user_scripts_json) {
  const std::string json = user_scripts_json ? std::string(user_scripts_json) : std::string();
  orbit::OrbitUserScriptRegistry::Get().SetGlobalScripts(
      orbit::ParseUserScriptSpecsJSON(json));
}

void OrbitSetUserAgent(const char* user_agent) {
  orbit::OrbitWebContentsHost::SetGlobalUserAgentOverride(
      user_agent ? std::string(user_agent) : std::string());
}

void OrbitGetCookies(const char* url, OrbitCookiesCallback callback, void* callback_opaque) {
  if (!callback) {
    return;
  }
  orbit::GetCookiesJSON(
      orbit::GetOrbitBrowserContext(), url ? std::string(url) : std::string(),
      base::BindOnce(
          [](OrbitCookiesCallback callback, void* opaque, std::string json) {
            callback(opaque, json.c_str());
          },
          callback, callback_opaque));
}

void OrbitDeleteCookies(const char* url, OrbitCompletionCallback callback, void* callback_opaque) {
  orbit::DeleteCookiesForURL(
      orbit::GetOrbitBrowserContext(), url ? std::string(url) : std::string(),
      base::BindOnce(
          [](OrbitCompletionCallback callback, void* opaque) {
            if (callback) {
              callback(opaque);
            }
          },
          callback, callback_opaque));
}

void OrbitSetCookies(const char* cookies_json, OrbitSetCookiesCallback callback, void* callback_opaque) {
  orbit::SetCookiesJSON(
      orbit::GetOrbitBrowserContext(),
      cookies_json ? std::string(cookies_json) : std::string(),
      base::BindOnce(
          [](OrbitSetCookiesCallback callback, void* opaque, int accepted_count) {
            if (callback) {
              callback(opaque, accepted_count);
            }
          },
          callback, callback_opaque));
}

void OrbitSetContentBlockingDecisionCallback(
    OrbitContentBlockingDecisionCallback callback, void* opaque) {
  orbit::g_content_blocking_decision_callback = callback;
  orbit::g_content_blocking_decision_opaque = opaque;
}

void OrbitSetContentBlockingActive(int active) {
  orbit::g_content_blocking_active.store(active != 0, std::memory_order_relaxed);
}

void OrbitLoadExtension(const char* directory_path,
                        OrbitLoadExtensionCallback callback,
                        void* callback_opaque) {
  orbit::LoadUnpackedExtension(
      orbit::GetOrbitBrowserContext(),
      directory_path ? std::string(directory_path) : std::string(),
      orbit::ExtensionLoadReason::kUserAction, callback, callback_opaque);
}

void OrbitLoadExtensionForStartup(const char* directory_path,
                                  OrbitLoadExtensionCallback callback,
                                  void* callback_opaque) {
  orbit::LoadUnpackedExtension(
      orbit::GetOrbitBrowserContext(),
      directory_path ? std::string(directory_path) : std::string(),
      orbit::ExtensionLoadReason::kBrowserStartup, callback, callback_opaque);
}

void OrbitUnloadExtension(const char* extension_id) {
  orbit::UnloadExtension(orbit::GetOrbitBrowserContext(),
                         extension_id ? std::string(extension_id) : std::string());
}

void OrbitUninstallExtension(const char* extension_id) {
  orbit::UninstallExtension(
      orbit::GetOrbitBrowserContext(),
      extension_id ? std::string(extension_id) : std::string());
}

const char* OrbitGetLoadedExtensionsJSON(void) {
  static base::NoDestructor<std::string> json;
  *json = orbit::GetLoadedExtensionsJSON(orbit::GetOrbitBrowserContext());
  return json->c_str();
}

void OrbitCancelDownload(const char* download_id) {
  orbit::CancelDownload(orbit::GetOrbitBrowserContext(),
                        download_id ? std::string(download_id) : std::string());
}

void OrbitPauseDownload(const char* download_id) {
  orbit::PauseDownload(orbit::GetOrbitBrowserContext(),
                       download_id ? std::string(download_id) : std::string());
}

void OrbitResumeDownload(const char* download_id) {
  orbit::ResumeDownload(orbit::GetOrbitBrowserContext(),
                        download_id ? std::string(download_id) : std::string());
}

namespace {

// http/https only -- matches Orbit/Engine/EngineTypes.swift's
// ContentSettingOrigin.normalize, the Swift-side twin of this same rule.
std::optional<url::Origin> PermissionOriginFor(const char* url) {
  if (!url) {
    return std::nullopt;
  }
  GURL gurl(url);
  if (!gurl.is_valid()) {
    return std::nullopt;
  }
  url::Origin origin = url::Origin::Create(gurl);
  if (origin.opaque() || (origin.scheme() != "http" && origin.scheme() != "https")) {
    return std::nullopt;
  }
  return origin;
}

}  // namespace

const char* OrbitGetContentSetting(const char* kind, const char* url) {
  static base::NoDestructor<std::string> result;
  *result = "unsupported";

  if (!orbit::g_browser_context || !kind) {
    return result->c_str();
  }
  std::optional<orbit::OrbitPermissionStore::Kind> parsed_kind =
      orbit::OrbitPermissionStore::KindFromString(kind);
  std::optional<url::Origin> origin = PermissionOriginFor(url);
  if (!parsed_kind || !origin) {
    return result->c_str();
  }

  switch (orbit::g_browser_context->permission_store()->Get(*parsed_kind, *origin)) {
    case orbit::OrbitPermissionStore::Decision::kAllow:
      *result = "allow";
      break;
    case orbit::OrbitPermissionStore::Decision::kBlock:
      *result = "block";
      break;
    case orbit::OrbitPermissionStore::Decision::kAsk:
      *result = "ask";
      break;
  }
  return result->c_str();
}

void OrbitSetContentSetting(const char* setting, const char* kind, const char* url) {
  if (!orbit::g_browser_context || !setting || !kind) {
    return;
  }
  std::optional<orbit::OrbitPermissionStore::Kind> parsed_kind =
      orbit::OrbitPermissionStore::KindFromString(kind);
  std::optional<url::Origin> origin = PermissionOriginFor(url);
  if (!parsed_kind || !origin) {
    return;
  }

  const std::string_view setting_view(setting);
  orbit::OrbitPermissionStore::Decision decision;
  if (setting_view == "allow") {
    decision = orbit::OrbitPermissionStore::Decision::kAllow;
  } else if (setting_view == "block") {
    decision = orbit::OrbitPermissionStore::Decision::kBlock;
  } else if (setting_view == "ask") {
    decision = orbit::OrbitPermissionStore::Decision::kAsk;
  } else {
    return;
  }
  orbit::g_browser_context->permission_store()->Set(*parsed_kind, *origin, decision);
}

void OrbitTabsCreated(OrbitWebContentsHandle handle,
                      int32_t tab_id,
                      int32_t window_id,
                      int32_t index,
                      int active,
                      int pinned) {
  orbit::OrbitTabRegistry::GetInstance().OnTabCreated(
      handle ? orbit::ToHost(handle)->web_contents() : nullptr, tab_id,
      window_id, index, active != 0, pinned != 0);
}

void OrbitTabsRemoved(int32_t tab_id, int window_closing) {
  orbit::OrbitTabRegistry::GetInstance().OnTabRemoved(tab_id, window_closing != 0);
}

void OrbitTabsActivated(int32_t tab_id, int32_t window_id, int32_t previous_tab_id) {
  orbit::OrbitTabRegistry::GetInstance().OnTabActivated(tab_id, window_id,
                                                        previous_tab_id);
}

void OrbitTabsMoved(int32_t tab_id, int32_t window_id, int32_t from_index,
                    int32_t to_index) {
  orbit::OrbitTabRegistry::GetInstance().OnTabMoved(tab_id, window_id, from_index,
                                                    to_index);
}

void OrbitTabsSetPinned(int32_t tab_id, int pinned) {
  orbit::OrbitTabRegistry::GetInstance().OnTabPinnedChanged(tab_id, pinned != 0);
}

void OrbitTabsIndexChanged(int32_t tab_id, int32_t index) {
  orbit::OrbitTabRegistry::GetInstance().OnTabIndexChanged(tab_id, index);
}

void OrbitWindowsCreated(int32_t window_id, int focused) {
  orbit::OrbitTabRegistry::GetInstance().OnWindowCreated(window_id, focused != 0);
}

void OrbitWindowsRemoved(int32_t window_id) {
  orbit::OrbitTabRegistry::GetInstance().OnWindowRemoved(window_id);
}

void OrbitWindowsFocusChanged(int32_t window_id) {
  orbit::OrbitTabRegistry::GetInstance().OnWindowFocusChanged(window_id);
}

void OrbitWindowsStateChanged(int32_t window_id, const char* state) {
  orbit::OrbitTabRegistry::GetInstance().OnWindowStateChanged(
      window_id, state ? std::string(state) : std::string("normal"));
}

namespace orbit {
namespace {

// Each trampoline closes over a copy of the raw C struct, not a pointer to
// it: Swift only guarantees its contents are valid for the OrbitSetTabsDelegate call itself.

bool CreateTabTrampoline(::OrbitTabsDelegate c_delegate,
                         int32_t window_id,
                         const std::string& url,
                         bool active,
                         bool pinned,
                         content::WebContents** out_web_contents,
                         int32_t* out_tab_id) {
  if (!c_delegate.create_tab) {
    return false;
  }
  OrbitWebContentsHandle handle = nullptr;
  const int ok = c_delegate.create_tab(c_delegate.opaque, window_id, url.c_str(),
                                       active ? 1 : 0, pinned ? 1 : 0, &handle,
                                       out_tab_id);
  if (!ok) {
    return false;
  }
  if (out_web_contents) {
    *out_web_contents = handle ? ToHost(handle)->web_contents() : nullptr;
  }
  return true;
}

bool UpdateTabUrlTrampoline(::OrbitTabsDelegate c_delegate, int32_t tab_id,
                            const std::string& url) {
  return c_delegate.update_tab_url &&
        c_delegate.update_tab_url(c_delegate.opaque, tab_id, url.c_str()) != 0;
}

bool ActivateTabTrampoline(::OrbitTabsDelegate c_delegate, int32_t tab_id) {
  return c_delegate.activate_tab &&
        c_delegate.activate_tab(c_delegate.opaque, tab_id) != 0;
}

bool RemoveTabTrampoline(::OrbitTabsDelegate c_delegate, int32_t tab_id) {
  return c_delegate.remove_tab &&
        c_delegate.remove_tab(c_delegate.opaque, tab_id) != 0;
}

bool SetTabPinnedTrampoline(::OrbitTabsDelegate c_delegate, int32_t tab_id,
                            bool pinned) {
  return c_delegate.set_tab_pinned &&
        c_delegate.set_tab_pinned(c_delegate.opaque, tab_id, pinned ? 1 : 0) != 0;
}

}  // namespace
}  // namespace orbit

void OrbitSetTabsDelegate(const ::OrbitTabsDelegate* delegate) {
  if (!delegate) {
    orbit::OrbitTabRegistry::GetInstance().SetDelegate(orbit::OrbitTabsDelegate());
    return;
  }
  const ::OrbitTabsDelegate c_delegate = *delegate;
  orbit::OrbitTabsDelegate cpp_delegate;
  cpp_delegate.create_tab =
      base::BindRepeating(&orbit::CreateTabTrampoline, c_delegate);
  cpp_delegate.update_tab_url =
      base::BindRepeating(&orbit::UpdateTabUrlTrampoline, c_delegate);
  cpp_delegate.activate_tab =
      base::BindRepeating(&orbit::ActivateTabTrampoline, c_delegate);
  cpp_delegate.remove_tab =
      base::BindRepeating(&orbit::RemoveTabTrampoline, c_delegate);
  cpp_delegate.set_tab_pinned =
      base::BindRepeating(&orbit::SetTabPinnedTrampoline, c_delegate);
  orbit::OrbitTabRegistry::GetInstance().SetDelegate(std::move(cpp_delegate));
}

void OrbitSetExtensionTabRequestCallback(
    OrbitExtensionTabRequestCallback callback, void* opaque) {
  orbit::g_extension_tab_request_callback = callback;
  orbit::g_extension_tab_request_opaque = opaque;
}

void OrbitSetNewContentRequestCallback(
    OrbitNewContentRequestCallback callback, void* opaque) {
  orbit::g_new_content_request_callback = callback;
  orbit::g_new_content_request_opaque = opaque;
}

void OrbitWebContentsRespondToExtensionRequest(OrbitWebContentsHandle handle,
                                               const char* request_id,
                                               const char* result_json) {
  if (!handle || !request_id) {
    return;
  }
  orbit::ToHost(handle)->RespondToNativeExtensionRequest(
      request_id, result_json ? std::string(result_json) : std::string());
}

namespace orbit {
namespace {

OrbitManagementDelegate g_management_delegate = {};
uint64_t g_next_management_request_id = 1;

std::map<uint64_t, base::OnceCallback<void(bool)>>& PendingUninstallConsents() {
  static base::NoDestructor<std::map<uint64_t, base::OnceCallback<void(bool)>>>
      pending;
  return *pending;
}

OrbitPermissionsConsentDelegate g_permissions_consent_delegate = {};
uint64_t g_next_permissions_request_id = 1;

std::map<uint64_t, base::OnceCallback<void(bool)>>& PendingPermissionsConsents() {
  static base::NoDestructor<std::map<uint64_t, base::OnceCallback<void(bool)>>>
      pending;
  return *pending;
}

}  // namespace

bool ManagementSetExtensionEnabled(const std::string& extension_id,
                                   bool enabled) {
  return g_management_delegate.set_enabled &&
         g_management_delegate.set_enabled(g_management_delegate.opaque,
                                           extension_id.c_str(),
                                           enabled ? 1 : 0) != 0;
}

bool ManagementUninstallExtension(const std::string& extension_id) {
  return g_management_delegate.uninstall &&
         g_management_delegate.uninstall(g_management_delegate.opaque,
                                         extension_id.c_str()) != 0;
}

bool ManagementRequestUninstallConsent(
    const std::string& extension_id,
    base::OnceCallback<void(bool)> callback) {
  if (!g_management_delegate.confirm_uninstall) {
    return false;
  }
  const uint64_t request_id = g_next_management_request_id++;
  PendingUninstallConsents()[request_id] = std::move(callback);
  g_management_delegate.confirm_uninstall(g_management_delegate.opaque,
                                          extension_id.c_str(), request_id);
  return true;
}

bool RequestPermissionsConsent(const std::string& request_json,
                               base::OnceCallback<void(bool)> callback) {
  if (!g_permissions_consent_delegate.request_consent) {
    return false;
  }
  const uint64_t request_id = g_next_permissions_request_id++;
  PendingPermissionsConsents()[request_id] = std::move(callback);
  g_permissions_consent_delegate.request_consent(
      g_permissions_consent_delegate.opaque, request_json.c_str(), request_id);
  return true;
}

}  // namespace orbit

void OrbitSetManagementDelegate(const OrbitManagementDelegate* delegate) {
  orbit::g_management_delegate =
      delegate ? *delegate : OrbitManagementDelegate{};
}

void OrbitManagementUninstallConsent(uint64_t request_id, int approved) {
  auto& pending = orbit::PendingUninstallConsents();
  auto it = pending.find(request_id);
  if (it == pending.end()) {
    return;
  }
  base::OnceCallback<void(bool)> callback = std::move(it->second);
  pending.erase(it);
  std::move(callback).Run(approved != 0);
}

void OrbitSetPermissionsConsentDelegate(
    const OrbitPermissionsConsentDelegate* delegate) {
  orbit::g_permissions_consent_delegate =
      delegate ? *delegate : OrbitPermissionsConsentDelegate{};

  // Whoever was going to answer these is gone, so refuse them rather than
  // leave chrome.permissions.request pending forever.
  std::map<uint64_t, base::OnceCallback<void(bool)>> abandoned;
  abandoned.swap(orbit::PendingPermissionsConsents());
  for (auto& entry : abandoned) {
    std::move(entry.second).Run(false);
  }
}

void OrbitPermissionsConsentResponse(uint64_t request_id, int approved) {
  auto& pending = orbit::PendingPermissionsConsents();
  auto it = pending.find(request_id);
  if (it == pending.end()) {
    return;
  }
  base::OnceCallback<void(bool)> callback = std::move(it->second);
  pending.erase(it);
  std::move(callback).Run(approved != 0);
}

void OrbitSetExtensionActionCallback(OrbitExtensionActionCallback callback,
                                     void* opaque) {
  orbit::OrbitExtensionActionDispatcher::GetInstance().SetCallback(callback,
                                                                    opaque);
}

void OrbitSetCertificateErrorCallback(OrbitCertificateErrorCallback callback,
                                      void* opaque) {
  orbit::g_certificate_error_callback = callback;
  orbit::g_certificate_error_opaque = opaque;
}

void OrbitWebContentsRespondToCertificateError(OrbitWebContentsHandle handle,
                                               uint64_t request_id,
                                               int allow) {
  if (!handle) {
    return;
  }
  orbit::ToHost(handle)->RespondToCertificateError(request_id, allow != 0);
}

const char* OrbitGetExtensionActionsJSON(void) {
  static base::NoDestructor<std::string> json;
  *json = orbit::OrbitExtensionActionDispatcher::GetInstance()
              .GetAllActionsJSON(orbit::GetOrbitBrowserContext());
  return json->c_str();
}

void OrbitSetSearchSuggestEnabledCallback(
    OrbitSearchSuggestEnabledCallback callback,
    void* opaque) {
  orbit::OrbitPreferenceEventRouter::GetInstance().SetSearchSuggestCallback(
      callback, opaque);
}

int OrbitGetSearchSuggestEnabled(void) {
  return orbit::OrbitPreferenceEventRouter::GetInstance()
                 .GetSearchSuggestEnabled()
             ? 1
             : 0;
}

void OrbitSetSearchSuggestEnabled(int enabled) {
  orbit::OrbitPreferenceEventRouter::GetInstance()
      .SetSearchSuggestEnabledUserValue(enabled != 0);
}
