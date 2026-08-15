// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_web_contents_host.h"

#import <AppKit/AppKit.h>

#include <algorithm>
#include <map>
#include <optional>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/files/file_path.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/no_destructor.h"
#include "base/files/file_util.h"
#include "base/numerics/safe_conversions.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/single_thread_task_runner.h"
#include "base/task/thread_pool.h"
#include "base/values.h"
#include "components/printing/browser/print_to_pdf/pdf_print_result.h"
#include "components/printing/browser/print_to_pdf/pdf_print_utils.h"
#include "components/printing/common/print.mojom.h"
#include "components/viz/common/frame_sinks/copy_output_result.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/context_menu_params.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/navigation_handle.h"
#include "content/public/browser/page_navigator.h"
#include "content/public/browser/permission_controller.h"
#include "content/public/browser/permission_descriptor_util.h"
#include "content/public/browser/permission_result.h"
#include "content/public/browser/picture_in_picture_window_controller.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/render_widget_host.h"
#include "content/public/browser/render_widget_host_view.h"
#include "content/public/browser/reload_type.h"
#include "content/public/browser/save_page_type.h"
#include "content/public/browser/video_picture_in_picture_window_controller.h"
#include "content/public/browser/visibility.h"
#include "content/public/browser/web_contents.h"
#include "content/public/common/isolated_world_ids.h"
#include "content/public/common/stop_find_action.h"
#include "mojo/public/cpp/bindings/associated_remote.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/base/net_errors.h"
#include "net/cert/x509_certificate.h"
#include "net/http/http_response_headers.h"
#include "net/ssl/ssl_info.h"
#include "orbit/bridge/orbit_bridge_internal.h"
#include "orbit/browser/orbit_devtools_frontend.h"
#include "orbit/browser/orbit_extension_web_contents_observer.h"
#include "orbit/browser/orbit_menu_manager.h"
#include "orbit/browser/orbit_print_manager.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "orbit/browser/orbit_web_navigation_event_router.h"
#include "orbit/common/orbit_user_script_spec.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "third_party/blink/public/common/permissions/permission_utils.h"
#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"
#include "third_party/blink/public/mojom/context_menu/context_menu.mojom.h"
#include "third_party/blink/public/mojom/favicon/favicon_url.mojom.h"
#include "third_party/blink/public/mojom/frame/find_in_page.mojom.h"
#include "third_party/blink/public/mojom/frame/user_activation_notification_type.mojom.h"
#include "third_party/blink/public/mojom/mediastream/media_stream.mojom.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "ui/base/page_transition_types.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/geometry/size.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace orbit {

namespace {

// The size a tab strip, sidebar row and command bar row all draw a favicon at,
// at 2x, with room for the 3x an external display can ask for. The renderer
// picks the closest frame an .ico actually contains and scales an SVG to it.
constexpr int kFaviconPreferredEdge = 64;
constexpr uint32_t kFaviconMaxEdge = 256;

// Higher wins. A declared icon always beats the /favicon.ico blink synthesises
// when a document declares none, and a real favicon beats a touch icon, which
// exists for a home-screen tile rather than a tab.
int FaviconCandidateScore(const blink::mojom::FaviconURL& candidate) {
  int score = candidate.is_default_icon ? 0 : 100;
  switch (candidate.icon_type) {
    case blink::mojom::FaviconIconType::kFavicon:
      return score + 20;
    case blink::mojom::FaviconIconType::kTouchIcon:
    case blink::mojom::FaviconIconType::kTouchPrecomposedIcon:
      return score + 10;
    case blink::mojom::FaviconIconType::kInvalid:
      return -1;
  }
}

// Mirrors orbit_bridge_api.h's OrbitWebContentsCallbacks.did_commit `kind`
// comment; kept in this one place rather than duplicated on the Swift side.
int PageTransitionToKind(ui::PageTransition transition,
                         content::ReloadType reload_type) {
  if (reload_type != content::ReloadType::NONE) {
    return 5;  // reload
  }
  if (transition & ui::PAGE_TRANSITION_FORWARD_BACK) {
    return 4;  // backForward
  }
  if (ui::PageTransitionIsRedirect(transition)) {
    return 6;  // redirect
  }
  if (ui::PageTransitionCoreTypeIs(transition, ui::PAGE_TRANSITION_TYPED)) {
    return 1;  // typed
  }
  if (ui::PageTransitionCoreTypeIs(transition, ui::PAGE_TRANSITION_LINK)) {
    return 2;  // linkActivated
  }
  if (ui::PageTransitionCoreTypeIs(transition,
                                   ui::PAGE_TRANSITION_FORM_SUBMIT)) {
    return 3;  // formSubmitted
  }
  if (ui::PageTransitionCoreTypeIs(transition, ui::PAGE_TRANSITION_RELOAD)) {
    return 5;  // reload
  }
  return 0;  // other
}

// Any world id other than content::ISOLATED_WORLD_ID_GLOBAL works; this is Orbit's
// own, distinct from whatever a future extensions content-script world uses.
constexpr int32_t kOrbitIsolatedWorldId = content::ISOLATED_WORLD_ID_CONTENT_END;

// Runs in kOrbitIsolatedWorldId: shares DOM/transient activation, not JS globals, so a
// page can't shadow requestPictureInPicture. Shadow roots walked only if no <video> found.
constexpr char kRequestPictureInPictureScript[] = R"JS(
(function() {
  function eligible(video) {
    return !video.disablePictureInPicture && video.readyState >= 1 &&
        typeof video.requestPictureInPicture === 'function';
  }
  function collect(root, found) {
    var all = root.querySelectorAll('*');
    for (var i = 0; i < all.length; i++) {
      if (all[i].localName === 'video') { found.push(all[i]); }
      if (all[i].shadowRoot) { collect(all[i].shadowRoot, found); }
    }
    return found;
  }
  var videos = Array.prototype.slice.call(document.querySelectorAll('video'));
  if (videos.length === 0) { videos = collect(document, []); }
  var target = null;
  for (var i = 0; i < videos.length; i++) {
    if (!eligible(videos[i])) { continue; }
    if (target === null) { target = videos[i]; }
    if (!videos[i].paused && !videos[i].ended) { target = videos[i]; break; }
  }
  if (target === null) { return false; }
  target.requestPictureInPicture().catch(function() {});
  return true;
})();
)JS";

std::map<content::WebContents*, OrbitWebContentsHost*>& HostRegistry() {
  static base::NoDestructor<std::map<content::WebContents*, OrbitWebContentsHost*>>
      registry;
  return *registry;
}

void RunJavaScriptResultCallback(OrbitJavaScriptResultCallback callback,
                                 void* opaque,
                                 base::Value value) {
  if (!callback) {
    return;
  }
  std::string json;
  if (!base::JSONWriter::Write(value, &json)) {
    json = "null";
  }
  callback(opaque, 1, json.c_str(), "");
}

// The reply callback is destroyed unrun if its frame goes away first. Swift's
// evaluateJavaScript suspends forever on a dropped reply, so every path here must answer.
void RunJavaScriptDroppedCallback(OrbitJavaScriptResultCallback callback,
                                  void* opaque) {
  if (!callback) {
    return;
  }
  callback(opaque, 0, "",
           "the frame was destroyed before the script returned a result");
}

// Process-wide, applied to every OrbitWebContentsHost -- see OrbitSetUserAgent.
std::string& GlobalUserAgentOverride() {
  static base::NoDestructor<std::string> ua;
  return *ua;
}

// Every navigation states the override explicitly: UA_OVERRIDE_INHERIT copies the
// previous entry's answer, so an unset override would never take effect, nor clear one.
content::NavigationController::UserAgentOverrideOption
CurrentUserAgentOverrideOption() {
  return GlobalUserAgentOverride().empty()
             ? content::NavigationController::UA_OVERRIDE_FALSE
             : content::NavigationController::UA_OVERRIDE_TRUE;
}

void DeliverCapturePreviewResult(OrbitCapturePreviewCallback callback,
                                 void* opaque,
                                 int success,
                                 std::vector<uint8_t> pixels,
                                 int32_t width,
                                 int32_t height,
                                 int32_t stride) {
  if (!callback) {
    return;
  }
  callback(opaque, success, success ? pixels.data() : nullptr, width, height, stride);
}

// CopyFromSurface may reply on any sequence; every Orbit callback is UI-only.
void HandleCapturePreviewResult(
    OrbitCapturePreviewCallback callback,
    void* opaque,
    scoped_refptr<base::SingleThreadTaskRunner> ui_task_runner,
    const content::CopyFromSurfaceResult& result) {
  if (!result.has_value() || result->bitmap.drawsNothing()) {
    ui_task_runner->PostTask(
        FROM_HERE, base::BindOnce(&DeliverCapturePreviewResult, callback, opaque, 0,
                                  std::vector<uint8_t>(), 0, 0, 0));
    return;
  }

  const SkBitmap& bitmap = result->bitmap;
  const int32_t width = bitmap.width();
  const int32_t height = bitmap.height();
  const int32_t stride = width * 4;
  std::vector<uint8_t> pixels(static_cast<size_t>(stride) * static_cast<size_t>(height));
  const SkImageInfo dst_info =
      SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
  const bool ok = bitmap.readPixels(dst_info, pixels.data(), stride, 0, 0);

  ui_task_runner->PostTask(
      FROM_HERE,
      base::BindOnce(&DeliverCapturePreviewResult, callback, opaque, ok ? 1 : 0,
                     ok ? std::move(pixels) : std::vector<uint8_t>(),
                     ok ? width : 0, ok ? height : 0, ok ? stride : 0));
}

// result[i] lines up with the i-th permission actually requested (audio first, then
// video), never with `request`'s own audio_type/video_type slots directly.
void HandleMediaPermissionsRequestResult(
    const content::MediaStreamRequest& request,
    content::MediaResponseCallback callback,
    const std::vector<content::PermissionResult>& result) {
  blink::mojom::StreamDevicesPtr devices = blink::mojom::StreamDevices::New();
  size_t result_pos = 0;

  if (request.audio_type == blink::mojom::MediaStreamType::DEVICE_AUDIO_CAPTURE) {
    if (result_pos < result.size() &&
        result[result_pos].status == blink::mojom::PermissionStatus::GRANTED) {
      devices->audio_device = blink::MediaStreamDevice(
          request.audio_type,
          request.requested_audio_device_ids.empty()
              ? ""
              : request.requested_audio_device_ids.front(),
          /*name=*/"");
    }
    ++result_pos;
  }

  if (request.video_type == blink::mojom::MediaStreamType::DEVICE_VIDEO_CAPTURE) {
    if (result_pos < result.size() &&
        result[result_pos].status == blink::mojom::PermissionStatus::GRANTED) {
      devices->video_device = blink::MediaStreamDevice(
          request.video_type,
          request.requested_video_device_ids.empty()
              ? ""
              : request.requested_video_device_ids.front(),
          /*name=*/"");
    }
  }

  blink::mojom::StreamDevicesSet stream_devices_set;
  if (devices->audio_device.has_value() || devices->video_device.has_value()) {
    stream_devices_set.stream_devices.emplace_back(std::move(devices));
  }
  std::move(callback).Run(
      stream_devices_set,
      stream_devices_set.stream_devices.empty()
          ? blink::mojom::MediaStreamRequestResult::NO_HARDWARE
          : blink::mojom::MediaStreamRequestResult::OK,
      nullptr);
}

// The actual file write happens on a ThreadPool sequence -- print_to_pdf::
// PdfPrintJob's own callback fires on the UI thread, and that thread must
// never block on disk I/O.
bool WritePdfBytes(base::FilePath target_path,
                   scoped_refptr<base::RefCountedMemory> data) {
  return base::WriteFile(target_path, *data);
}

void HandlePdfPrintResult(base::FilePath target_path,
                          OrbitPrintToPdfCallback callback,
                          void* callback_opaque,
                          print_to_pdf::PdfPrintResult result,
                          scoped_refptr<base::RefCountedMemory> data) {
  if (result != print_to_pdf::PdfPrintResult::kPrintSuccess || !data) {
    if (callback) {
      callback(callback_opaque, 0);
    }
    return;
  }
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(&WritePdfBytes, target_path, data),
      base::BindOnce(
          [](OrbitPrintToPdfCallback callback, void* opaque, bool wrote_ok) {
            if (callback) {
              callback(opaque, wrote_ok ? 1 : 0);
            }
          },
          callback, callback_opaque));
}

}  // namespace

OrbitWebContentsHost::OrbitWebContentsHost(
    content::BrowserContext* browser_context) {
  content::WebContents::CreateParams params(browser_context);
  InitWithWebContents(content::WebContents::Create(params));
}

OrbitWebContentsHost::OrbitWebContentsHost(
    std::unique_ptr<content::WebContents> web_contents) {
  InitWithWebContents(std::move(web_contents));
}

void OrbitWebContentsHost::InitWithWebContents(
    std::unique_ptr<content::WebContents> web_contents) {
  web_contents_ = std::move(web_contents);
  content::BrowserContext* browser_context = web_contents_->GetBrowserContext();
  web_contents_->SetDelegate(this);
  OrbitExtensionWebContentsObserver::CreateForWebContents(web_contents_.get());
  OrbitPrintManager::CreateForWebContents(web_contents_.get());
  Observe(web_contents_.get());
  script_channel_receivers_.emplace(web_contents_.get(), this);
  HostRegistry()[web_contents_.get()] = this;
  OrbitUserScriptRegistry::Get().AddObserver(this);
  ApplyUserAgentOverride();

  zoom_level_changed_subscription_ =
      content::HostZoomMap::GetDefaultForBrowserContext(browser_context)
          ->AddZoomLevelChangedCallback(base::BindRepeating(
              [](OrbitWebContentsHost* self,
                const content::HostZoomMap::ZoomLevelChange&) {
                self->ReportZoomFactorIfChanged();
              },
              base::Unretained(this)));
}

OrbitWebContentsHost::~OrbitWebContentsHost() {
  // Before anything else, while web_contents_ is still whole: refuse every pending
  // certificate error, or content:: keeps its URLRequest alive waiting for a reply.
  DenyPendingCertificateDecisions();
  StopWaitingForAutoResizeMinimum();
  // A DevToolsAgentHost must never outlive the WebContents it debugs.
  NotifyWebContentsHostDestroyed(this);
  // Before ~WebContentsImpl can dispatch back into a half-destroyed `this`.
  web_contents_->SetDelegate(nullptr);
  // Destroying a WebContents with a pending navigation reenters DidFinishNavigation() on
  // every observer via ~NavigationRequest(); Observe(nullptr) detaches `this` first.
  Observe(nullptr);
  // content:: never reports PiP exit for a tab closed while its video was still floating
  // (CloseInternal early-returns during destruction), so this reports it explicitly.
  ReportPictureInPictureState(false);
  OrbitUserScriptRegistry::Get().RemoveObserver(this);
  HostRegistry().erase(web_contents_.get());
}

// static
OrbitWebContentsHost* OrbitWebContentsHost::FromWebContents(
    content::WebContents* web_contents) {
  auto it = HostRegistry().find(web_contents);
  return it == HostRegistry().end() ? nullptr : it->second;
}

// static
OrbitWebContentsHost* OrbitWebContentsHost::AnyLiveHost() {
  auto& registry = HostRegistry();
  return registry.empty() ? nullptr : registry.begin()->second;
}

// static
void OrbitWebContentsHost::NotifyAllPreferencesChanged() {
  for (auto& entry : HostRegistry()) {
    entry.first->NotifyPreferencesChanged();
  }
}

void OrbitWebContentsHost::SetCallbacks(
    const OrbitWebContentsCallbacks& callbacks) {
  callbacks_ = callbacks;
}

void* OrbitWebContentsHost::GetNativeView() {
  NSView* view = web_contents_->GetNativeView().GetNativeNSView();
  return (__bridge void*)view;
}

void OrbitWebContentsHost::SetVisible(bool visible) {
  if (!web_contents_ || web_contents_->IsBeingDestroyed()) {
    return;
  }
  // UpdateWebContentsVisibility, not WasShown/WasHidden: it is the entry point
  // content/public/browser/web_contents.h documents for the first transition
  // to VISIBLE, and the only one that clears did_first_set_visible_.
  web_contents_->UpdateWebContentsVisibility(
      visible ? content::Visibility::VISIBLE : content::Visibility::HIDDEN);
}

void OrbitWebContentsHost::LoadURL(const std::string& url) {
  GURL gurl(url);
  if (!gurl.is_valid()) {
    return;
  }
  content::NavigationController::LoadURLParams params(gurl);
  params.override_user_agent = CurrentUserAgentOverrideOption();
  web_contents_->GetController().LoadURLWithParams(params);
}

void OrbitWebContentsHost::Reload(bool bypass_cache) {
  web_contents_->GetController().Reload(
      bypass_cache ? content::ReloadType::BYPASSING_CACHE
                   : content::ReloadType::NORMAL,
      /*check_for_repost=*/false);
}

void OrbitWebContentsHost::Stop() {
  web_contents_->Stop();
}

void OrbitWebContentsHost::GoBack() {
  web_contents_->GetController().GoBack();
}

void OrbitWebContentsHost::GoForward() {
  web_contents_->GetController().GoForward();
}

void OrbitWebContentsHost::GoToOffset(int offset) {
  web_contents_->GetController().GoToOffset(offset);
}

bool OrbitWebContentsHost::CanGoBack() {
  return web_contents_->GetController().CanGoBack();
}

bool OrbitWebContentsHost::CanGoForward() {
  return web_contents_->GetController().CanGoForward();
}

void OrbitWebContentsHost::Focus() {
  web_contents_->Focus();
}

void OrbitWebContentsHost::Cut() {
  web_contents_->Cut();
}

void OrbitWebContentsHost::Copy() {
  web_contents_->Copy();
}

void OrbitWebContentsHost::Paste() {
  web_contents_->Paste();
}

void OrbitWebContentsHost::SelectAll() {
  web_contents_->SelectAll();
}

void OrbitWebContentsHost::EvaluateJavaScript(
    const std::string& script,
    int world,
    bool user_gesture,
    OrbitJavaScriptResultCallback callback,
    void* callback_opaque) {
  content::RenderFrameHost* rfh = web_contents_->GetPrimaryMainFrame();
  if (!rfh || !rfh->IsRenderFrameLive()) {
    if (callback) {
      callback(callback_opaque, 0, "", "no live main frame to evaluate script in");
    }
    return;
  }

  auto result_callback = mojo::WrapCallbackWithDropHandler(
      base::BindOnce(&RunJavaScriptResultCallback, callback, callback_opaque),
      base::BindOnce(&RunJavaScriptDroppedCallback, callback, callback_opaque));
  const std::u16string script16 = base::UTF8ToUTF16(script);

  if (world == 0) {
    // No devtools/CDP round-trip: ExecuteJavaScript is hard-restricted by
    // RenderFrameHostImpl::CanExecuteJavaScript() to chrome:// and
    // devtools:// documents (a CHECK, not a soft failure), so it cannot be
    // used on ordinary web content -- ExecuteJavaScriptForTests, despite the
    // name, is content::'s only unrestricted main-world entry point and is
    // exactly what this needs.
    if (user_gesture) {
      rfh->ExecuteJavaScriptWithUserGestureForTests(  // IN-TEST
          script16, std::move(result_callback),
          content::ISOLATED_WORLD_ID_GLOBAL);
    } else {
      rfh->ExecuteJavaScriptForTests(  // IN-TEST
          script16, std::move(result_callback),
          content::ISOLATED_WORLD_ID_GLOBAL);
    }
  } else {
    rfh->ExecuteJavaScriptInIsolatedWorld(
        script16, std::move(result_callback), kOrbitIsolatedWorldId);
  }
}

void OrbitWebContentsHost::AddLocalUserScript(const std::string& json) {
  // A single-element JSON array reuses ParseUserScriptSpecsJSON's field
  // parsing instead of duplicating it for one object.
  std::vector<UserScriptSpec> parsed =
      ParseUserScriptSpecsJSON("[" + json + "]");
  if (parsed.empty()) {
    return;
  }
  local_scripts_[parsed.front().id] = std::move(parsed.front());
  PushScriptsToAllFrames();
}

const char* OrbitWebContentsHost::SessionHistoryJSON() {
  content::NavigationController& controller = web_contents_->GetController();
  const int current_index = controller.GetLastCommittedEntryIndex();

  base::ListValue entries;
  for (int i = 0; i < controller.GetEntryCount(); ++i) {
    content::NavigationEntry* entry = controller.GetEntryAtIndex(i);
    if (!entry) {
      continue;
    }
    base::DictValue dict;
    dict.Set("id", entry->GetUniqueID());
    dict.Set("url", entry->GetVirtualURL().spec());
    dict.Set("title", base::UTF16ToUTF8(entry->GetTitleForDisplay()));
    dict.Set("offset", i - current_index);
    entries.Append(std::move(dict));
  }

  if (!base::JSONWriter::Write(entries, &session_history_json_)) {
    session_history_json_ = "[]";
  }
  return session_history_json_.c_str();
}

const char* OrbitWebContentsHost::ExtensionContextMenuJSON() {
  extension_context_menu_json_ = "[]";
  if (!last_context_menu_params_) {
    return extension_context_menu_json_.c_str();
  }
  base::ListValue groups =
      OrbitMenuManager::GetInstance().MatchingItemsValue(
          *last_context_menu_params_);
  if (!base::JSONWriter::Write(groups, &extension_context_menu_json_)) {
    extension_context_menu_json_ = "[]";
  }
  return extension_context_menu_json_.c_str();
}

void OrbitWebContentsHost::ExecuteExtensionContextMenuItem(
    const std::string& extension_id,
    bool has_uid,
    int uid,
    const std::string& string_uid) {
  if (!last_context_menu_params_) {
    return;
  }
  OrbitMenuItemId id(extension_id);
  if (has_uid) {
    id.uid = uid;
  } else {
    id.string_uid = string_uid;
  }
  OrbitMenuManager::GetInstance().ExecuteCommand(
      web_contents_.get(),
      content::RenderFrameHost::FromID(last_context_menu_frame_id_),
      *last_context_menu_params_, id);
}

void OrbitWebContentsHost::LoadHTML(const std::string& html,
                                    const std::string& base_url) {
  content::NavigationController::LoadURLParams params{GURL()};
  // Base64, not raw concatenation: `html` can contain '#', '%' and arbitrary bytes that
  // would otherwise corrupt the data: URL. Matches content::Shell::LoadDataWithBaseURL.
  params.url = GURL("data:text/html;charset=utf-8;base64," + base::Base64Encode(html));
  params.load_type = content::NavigationController::LOAD_TYPE_DATA;
  const GURL base(base_url);
  params.base_url_for_data_url = base;
  params.virtual_url_for_special_cases = base.is_valid() ? base : params.url;
  params.override_user_agent = CurrentUserAgentOverrideOption();
  web_contents_->GetController().LoadURLWithParams(params);
}

void OrbitWebContentsHost::SavePage(const std::string& target_path) {
  web_contents_->SavePage(base::FilePath::FromUTF8Unsafe(target_path),
                          base::FilePath(), content::SAVE_PAGE_TYPE_AS_MHTML);
}

void OrbitWebContentsHost::PrintToPdf(const std::string& target_path,
                                      OrbitPrintToPdfCallback callback,
                                      void* callback_opaque) {
  content::RenderFrameHost* rfh = web_contents_->GetPrimaryMainFrame();
  if (!rfh || !rfh->IsRenderFrameLive()) {
    if (callback) {
      callback(callback_opaque, 0);
    }
    return;
  }

  // Every argument left unset uses print_to_pdf::GetPrintPagesParams' own defaults --
  // the closest match to "print the page" with no print-preview UI.
  std::variant<printing::mojom::PrintPagesParamsPtr, std::string> params =
      print_to_pdf::GetPrintPagesParams(
          rfh->GetLastCommittedURL(), /*landscape=*/std::nullopt,
          /*display_header_footer=*/std::nullopt, /*print_background=*/std::nullopt,
          /*scale=*/std::nullopt, /*paper_width=*/std::nullopt,
          /*paper_height=*/std::nullopt, /*margin_top=*/std::nullopt,
          /*margin_bottom=*/std::nullopt, /*margin_left=*/std::nullopt,
          /*margin_right=*/std::nullopt, /*header_template=*/std::nullopt,
          /*footer_template=*/std::nullopt, /*prefer_css_page_size=*/std::nullopt,
          /*generate_tagged_pdf=*/std::nullopt, /*generate_document_outline=*/std::nullopt);
  if (!std::holds_alternative<printing::mojom::PrintPagesParamsPtr>(params)) {
    if (callback) {
      callback(callback_opaque, 0);
    }
    return;
  }

  OrbitPrintManager::FromWebContents(web_contents_.get())
      ->PrintToPdf(rfh, /*page_ranges=*/std::string(),
                  std::move(std::get<printing::mojom::PrintPagesParamsPtr>(params)),
                  base::BindOnce(&HandlePdfPrintResult,
                                 base::FilePath::FromUTF8Unsafe(target_path), callback,
                                 callback_opaque));
}

void OrbitWebContentsHost::Find(const std::string& text,
                                bool forward,
                                bool match_case,
                                bool find_next) {
  ++find_request_id_;
  auto options = blink::mojom::FindOptions::New();
  options->forward = forward;
  options->match_case = match_case;
  options->new_session = !find_next;
  // No debounce: this is an explicit "find now" call, and any typing delay
  // belongs to the find bar that drives it.
  web_contents_->Find(find_request_id_, base::UTF8ToUTF16(text), std::move(options),
                      /*skip_delay=*/true);
}

void OrbitWebContentsHost::StopFinding(int action) {
  content::StopFindAction stop_action = content::STOP_FIND_ACTION_CLEAR_SELECTION;
  switch (action) {
    case 1:
      stop_action = content::STOP_FIND_ACTION_KEEP_SELECTION;
      break;
    case 2:
      stop_action = content::STOP_FIND_ACTION_ACTIVATE_SELECTION;
      break;
    default:
      break;
  }
  web_contents_->StopFinding(stop_action);
}

void OrbitWebContentsHost::SetZoomFactor(double factor) {
  content::HostZoomMap::SetZoomLevel(web_contents_.get(),
                                     blink::ZoomFactorToZoomLevel(factor));
  // SendZoomLevelChange notifies subscribers asynchronously-in-practice but not
  // synchronously-guaranteed, so report explicitly rather than rely on the round trip.
  ReportZoomFactorIfChanged();
}

void OrbitWebContentsHost::EnableAutoResize(double min_width,
                                            double min_height,
                                            double max_width,
                                            double max_height) {
  gfx::Size min_size(base::ClampRound(min_width), base::ClampRound(min_height));
  gfx::Size max_size(base::ClampRound(max_width), base::ClampRound(max_height));
  if (max_size.IsEmpty()) {
    return;
  }
  min_size.SetToMin(max_size);
  auto_resize_min_ = min_size;
  auto_resize_max_ = max_size;
  ApplyAutoResizeToMainFrame();
}

// Auto-resize width floors at the widget's size when it turns on and can't be set in the
// same update as sizing; put the widget at the minimum first, hand off once the renderer acks it.
void OrbitWebContentsHost::ApplyAutoResizeToMainFrame() {
  if (auto_resize_max_.IsEmpty()) {
    return;
  }
  content::RenderFrameHost* rfh = web_contents_->GetPrimaryMainFrame();
  if (!rfh || !rfh->IsRenderFrameLive() || !rfh->GetView()) {
    return;
  }
  content::RenderWidgetHostView* view = rfh->GetView();
  // See OrbitWebContentsEnableAutoResize's comment: the reported size is the
  // document's layout size, so any non-neutral zoom would scale it and
  // mis-size whatever adopts it.
  content::HostZoomMap::GetDefaultForBrowserContext(
      web_contents_->GetBrowserContext())
      ->SetTemporaryZoomLevel(rfh->GetGlobalId(), 0.0);

  StopWaitingForAutoResizeMinimum();

  content::RenderWidgetHost* widget = view->GetRenderWidgetHost();
  // Nothing to deliver: sizing has not already been handed to this widget and
  // it is at the minimum, so the renderer has it. Waiting for an ack that
  // nothing is going to produce would leave auto-resize off forever.
  if (widget != auto_resize_enabled_widget_ &&
      view->GetViewBounds().size() == auto_resize_min_) {
    EnableAutoResizeOnMainFrame();
    return;
  }

  // DisableAutoResize, not SetSize: Blink ignores a raw size while still in auto-resize
  // mode. This turns it off and sets the size in one update, the pairing content:: expects.
  auto_resize_enabled_widget_ = nullptr;
  view->DisableAutoResize(auto_resize_min_);
  if (view->GetViewBounds().size() != auto_resize_min_) {
    // The platform refused the resize outright, so there is no acknowledgement
    // coming and nothing better to wait for.
    EnableAutoResizeOnMainFrame();
    return;
  }
  auto_resize_pending_widget_ = widget;
  widget->AddObserver(this);
}

void OrbitWebContentsHost::RenderWidgetHostDidUpdateVisualProperties(
    content::RenderWidgetHost* widget_host) {
  if (widget_host != auto_resize_pending_widget_) {
    return;
  }
  // This is the one moment an update the throttle swallowed can be flushed. True means
  // the minimum has only now gone to the renderer; its ack is still to come.
  if (widget_host->SynchronizeVisualProperties()) {
    return;
  }
  StopWaitingForAutoResizeMinimum();
  // Posted, not called here: DidUpdateVisualProperties reads auto_resize_enabled_ again
  // right after this returns, and would report the minimum as the document's own size.
  content::GetUIThreadTaskRunner({})->PostTask(
      FROM_HERE, base::BindOnce(&OrbitWebContentsHost::EnableAutoResizeOnMainFrame,
                                weak_factory_.GetWeakPtr()));
}

void OrbitWebContentsHost::RenderWidgetHostDestroyed(
    content::RenderWidgetHost* widget_host) {
  // Never RemoveObserver here: the list is being torn down with the widget.
  if (widget_host == auto_resize_pending_widget_) {
    auto_resize_pending_widget_ = nullptr;
  }
  if (widget_host == auto_resize_enabled_widget_) {
    auto_resize_enabled_widget_ = nullptr;
  }
}

void OrbitWebContentsHost::StopWaitingForAutoResizeMinimum() {
  if (!auto_resize_pending_widget_) {
    return;
  }
  auto_resize_pending_widget_->RemoveObserver(this);
  auto_resize_pending_widget_ = nullptr;
}

void OrbitWebContentsHost::EnableAutoResizeOnMainFrame() {
  if (auto_resize_max_.IsEmpty()) {
    return;
  }
  content::RenderFrameHost* rfh = web_contents_->GetPrimaryMainFrame();
  if (!rfh || !rfh->IsRenderFrameLive() || !rfh->GetView()) {
    return;
  }
  content::RenderWidgetHostView* view = rfh->GetView();
  if (view->GetViewBounds().size() != auto_resize_min_) {
    // Something resized the host between the acknowledgement and this task, so
    // the renderer no longer holds the minimum. Start again rather than hand
    // sizing over on top of a width that would floor every later report.
    ApplyAutoResizeToMainFrame();
    return;
  }
  view->EnableAutoResize(auto_resize_min_, auto_resize_max_);
  auto_resize_enabled_widget_ = view->GetRenderWidgetHost();
}

void OrbitWebContentsHost::CapturePreview(bool has_rect,
                                          double rect_x,
                                          double rect_y,
                                          double rect_width,
                                          double rect_height,
                                          double target_width,
                                          double target_height,
                                          OrbitCapturePreviewCallback callback,
                                          void* callback_opaque) {
  content::RenderWidgetHostView* view = web_contents_->GetRenderWidgetHostView();
  if (!view || !view->IsSurfaceAvailableForCopy()) {
    if (callback) {
      callback(callback_opaque, 0, nullptr, 0, 0, 0);
    }
    return;
  }

  gfx::Rect src_rect;
  if (has_rect) {
    src_rect = gfx::Rect(base::ClampRound(rect_x), base::ClampRound(rect_y),
                         base::ClampRound(rect_width), base::ClampRound(rect_height));
  }
  gfx::Size output_size;
  if (target_width > 0 && target_height > 0) {
    output_size = gfx::Size(base::ClampRound(target_width), base::ClampRound(target_height));
  }

  view->CopyFromSurface(
      src_rect, output_size, base::Seconds(5),
      base::BindOnce(&HandleCapturePreviewResult, callback, callback_opaque,
                     content::GetUIThreadTaskRunner({})));
}

void OrbitWebContentsHost::RequestDownloadTarget(const std::string& download_id,
                                                 const std::string& suggested_name,
                                                 const std::string& mime_type,
                                                 int64_t total_bytes,
                                                 const std::string& source_url,
                                                 OrbitDownloadTargetCallback callback,
                                                 void* callback_opaque) {
  if (!callbacks_.will_begin_download) {
    if (callback) {
      callback(callback_opaque, "");
    }
    return;
  }
  callbacks_.will_begin_download(callbacks_.opaque, download_id.c_str(),
                                 suggested_name.c_str(), mime_type.c_str(),
                                 total_bytes, source_url.c_str(), callback,
                                 callback_opaque);
}

void OrbitWebContentsHost::ReportDownloadProgress(const std::string& download_id,
                                                  int64_t received_bytes,
                                                  int64_t total_bytes,
                                                  int state) {
  if (!callbacks_.download_progress_changed) {
    return;
  }
  callbacks_.download_progress_changed(callbacks_.opaque, download_id.c_str(),
                                       received_bytes, total_bytes, state);
}

void OrbitWebContentsHost::RequestPermissionPrompt(const std::string& kinds_json,
                                                   const std::string& origin,
                                                   OrbitPermissionDecisionCallback callback,
                                                   void* callback_opaque) {
  if (!callbacks_.request_permission) {
    if (callback) {
      callback(callback_opaque, 0);
    }
    return;
  }
  callbacks_.request_permission(callbacks_.opaque, kinds_json.c_str(), origin.c_str(),
                                callback, callback_opaque);
}

void OrbitWebContentsHost::HandleCertificateError(
    int cert_error,
    const net::SSLInfo& ssl_info,
    const GURL& request_url,
    bool strict_enforcement,
    base::OnceCallback<void(content::CertificateRequestResultType)> callback) {
  // No certificate to describe means nothing the user could reason about, so
  // the error is not offered as a decision at all.
  const bool overridable = !strict_enforcement && ssl_info.cert != nullptr;

  CertificateErrorReport report;
  report.request_url = request_url.spec();
  report.host = request_url.host();
  report.cert_error = cert_error;
  report.error_name = net::ErrorToShortString(cert_error);
  report.overridable = overridable;
  if (ssl_info.cert) {
    report.issuer = ssl_info.cert->issuer().GetDisplayName();
    report.subject = ssl_info.cert->subject().GetDisplayName();
    if (!ssl_info.cert->valid_start().is_null()) {
      report.valid_from =
          ssl_info.cert->valid_start().InSecondsFSinceUnixEpoch();
    }
    if (!ssl_info.cert->valid_expiry().is_null()) {
      report.valid_until =
          ssl_info.cert->valid_expiry().InSecondsFSinceUnixEpoch();
    }
  }

  const uint64_t request_id = ++next_certificate_request_id_;
  pending_certificate_decisions_.emplace(
      request_id,
      PendingCertificateDecision{std::move(callback), overridable});

  // Recorded before dispatching, so an answer that somehow arrived inside the
  // dispatch finds its entry -- and so a dispatch that fails resolves through
  // the same one path as every other refusal.
  if (!DispatchCertificateError(this, request_id, report)) {
    ResolveCertificateDecision(request_id, false);
  }
}

void OrbitWebContentsHost::RespondToCertificateError(uint64_t request_id,
                                                     bool allow) {
  ResolveCertificateDecision(request_id, allow);
}

void OrbitWebContentsHost::ResolveCertificateDecision(uint64_t request_id,
                                                      bool allow) {
  auto it = pending_certificate_decisions_.find(request_id);
  if (it == pending_certificate_decisions_.end()) {
    return;
  }
  PendingCertificateDecision decision = std::move(it->second);
  pending_certificate_decisions_.erase(it);
  const bool proceed = allow && decision.overridable;
  std::move(decision.callback)
      .Run(proceed ? content::CERTIFICATE_REQUEST_RESULT_TYPE_CONTINUE
                   : content::CERTIFICATE_REQUEST_RESULT_TYPE_DENY);
}

void OrbitWebContentsHost::DenyPendingCertificateDecisions() {
  std::map<uint64_t, PendingCertificateDecision> pending;
  pending.swap(pending_certificate_decisions_);
  for (auto& [request_id, decision] : pending) {
    std::move(decision.callback)
        .Run(content::CERTIFICATE_REQUEST_RESULT_TYPE_DENY);
  }
}

void OrbitWebContentsHost::NotifyDevToolsClosed() {
  if (callbacks_.devtools_closed) {
    callbacks_.devtools_closed(callbacks_.opaque);
  }
}

void OrbitWebContentsHost::NotifyDevToolsDockedChanged(bool is_docked) {
  if (callbacks_.devtools_docked_changed) {
    callbacks_.devtools_docked_changed(callbacks_.opaque, is_docked ? 1 : 0);
  }
}

void OrbitWebContentsHost::NotifyDevToolsInspectedPageBounds(
    int x,
    int y,
    int width,
    int height,
    bool hide_inspected_page) {
  if (callbacks_.devtools_inspected_page_bounds) {
    callbacks_.devtools_inspected_page_bounds(callbacks_.opaque, x, y, width,
                                              height,
                                              hide_inspected_page ? 1 : 0);
  }
}

void OrbitWebContentsHost::NotifyDevToolsCloseRequested() {
  if (callbacks_.devtools_close_requested) {
    callbacks_.devtools_close_requested(callbacks_.opaque);
  }
}

void OrbitWebContentsHost::NotifyDevToolsBringToFront() {
  if (callbacks_.devtools_bring_to_front) {
    callbacks_.devtools_bring_to_front(callbacks_.opaque);
  }
}

void OrbitWebContentsHost::RequestFromNativeExtensionBridge(
    const std::string& method,
    base::ListValue args,
    base::OnceCallback<void(std::string result_json)> callback) {
  if (!callbacks_.native_extension_request) {
    std::move(callback).Run(
        R"({"ok":false,"error":{"message":"No native_extension_request callback installed."}})");
    return;
  }

  const std::string request_id =
      "n" + base::NumberToString(++next_native_extension_request_id_);

  std::string args_json;
  base::JSONWriter::Write(args, &args_json);

  pending_native_extension_requests_[request_id] = std::move(callback);
  callbacks_.native_extension_request(callbacks_.opaque, request_id.c_str(),
                                      method.c_str(), args_json.c_str());
}

void OrbitWebContentsHost::RespondToNativeExtensionRequest(
    const std::string& request_id,
    const std::string& result_json) {
  auto it = pending_native_extension_requests_.find(request_id);
  if (it == pending_native_extension_requests_.end()) {
    return;
  }
  base::OnceCallback<void(std::string)> callback = std::move(it->second);
  pending_native_extension_requests_.erase(it);
  std::move(callback).Run(result_json);
}

void OrbitWebContentsHost::RequestMediaAccessPermission(
    content::WebContents* web_contents,
    const content::MediaStreamRequest& request,
    content::MediaResponseCallback callback) {
  std::vector<blink::mojom::PermissionDescriptorPtr> permissions;

  if (request.audio_type == blink::mojom::MediaStreamType::DEVICE_AUDIO_CAPTURE) {
    permissions.push_back(
        content::PermissionDescriptorUtil::CreatePermissionDescriptorForPermissionType(
            blink::PermissionType::AUDIO_CAPTURE));
  } else if (request.audio_type != blink::mojom::MediaStreamType::NO_SERVICE) {
    std::move(callback).Run(blink::mojom::StreamDevicesSet(),
                            blink::mojom::MediaStreamRequestResult::NOT_SUPPORTED, nullptr);
    return;
  }

  if (request.video_type == blink::mojom::MediaStreamType::DEVICE_VIDEO_CAPTURE) {
    permissions.push_back(
        content::PermissionDescriptorUtil::CreatePermissionDescriptorForPermissionType(
            blink::PermissionType::VIDEO_CAPTURE));
  } else if (request.video_type != blink::mojom::MediaStreamType::NO_SERVICE) {
    // Tab/desktop/window capture (DISPLAY_VIDEO_CAPTURE and friends) needs a
    // native source-picker UI Orbit does not have -- refused, never silently
    // granted.
    std::move(callback).Run(blink::mojom::StreamDevicesSet(),
                            blink::mojom::MediaStreamRequestResult::NOT_SUPPORTED, nullptr);
    return;
  }

  content::RenderFrameHost* render_frame_host =
      content::RenderFrameHost::FromID(request.render_process_id, request.render_frame_id);
  if (!render_frame_host) {
    std::move(callback).Run(blink::mojom::StreamDevicesSet(),
                            blink::mojom::MediaStreamRequestResult::INVALID_STATE, nullptr);
    return;
  }
  if (url::Origin::Create(request.security_origin) !=
      render_frame_host->GetLastCommittedOrigin()) {
    std::move(callback).Run(blink::mojom::StreamDevicesSet(),
                            blink::mojom::MediaStreamRequestResult::INVALID_SECURITY_ORIGIN,
                            nullptr);
    return;
  }

  content::PermissionController* permission_controller =
      web_contents_->GetBrowserContext()->GetPermissionController();
  permission_controller->RequestPermissionsFromCurrentDocument(
      render_frame_host,
      content::PermissionRequestDescription(std::move(permissions), request.user_gesture),
      base::BindOnce(&HandleMediaPermissionsRequestResult, request, std::move(callback)));
}

bool OrbitWebContentsHost::CheckMediaAccessPermission(
    content::RenderFrameHost* render_frame_host,
    const url::Origin& security_origin,
    blink::mojom::MediaStreamType type) {
  blink::PermissionType permission;
  switch (type) {
    case blink::mojom::MediaStreamType::DEVICE_AUDIO_CAPTURE:
      permission = blink::PermissionType::AUDIO_CAPTURE;
      break;
    case blink::mojom::MediaStreamType::DEVICE_VIDEO_CAPTURE:
      permission = blink::PermissionType::VIDEO_CAPTURE;
      break;
    default:
      return false;
  }
  if (security_origin != render_frame_host->GetLastCommittedOrigin()) {
    return false;
  }

  content::PermissionController* permission_controller =
      web_contents_->GetBrowserContext()->GetPermissionController();
  return permission_controller->GetPermissionStatusForCurrentDocument(
             content::PermissionDescriptorUtil::CreatePermissionDescriptorForPermissionType(
                 permission),
             render_frame_host) == blink::mojom::PermissionStatus::GRANTED;
}

content::PictureInPictureResult OrbitWebContentsHost::EnterPictureInPicture(
    content::WebContents*) {
  return content::PictureInPictureResult::kSuccess;
}

void OrbitWebContentsHost::MediaPictureInPictureChanged(
    bool is_picture_in_picture) {
  ReportPictureInPictureState(is_picture_in_picture);
}

void OrbitWebContentsHost::ReportPictureInPictureState(bool is_active) {
  if (reported_picture_in_picture_active_ == is_active) {
    return;
  }
  reported_picture_in_picture_active_ = is_active;
  if (callbacks_.picture_in_picture_changed) {
    callbacks_.picture_in_picture_changed(callbacks_.opaque, is_active ? 1 : 0);
  }
}

void OrbitWebContentsHost::ExitPictureInPicture() {
  ClosePictureInPictureWindow(/*should_pause_video=*/false);
}

void OrbitWebContentsHost::ClosePictureInPictureWindow(bool should_pause_video) {
  if (!web_contents_->HasPictureInPictureVideo()) {
    return;
  }
  content::PictureInPictureWindowController::
      GetOrCreateVideoPictureInPictureController(web_contents_.get())
          ->Close(should_pause_video);
}

void OrbitWebContentsHost::ActivateContents(content::WebContents*) {
  if (callbacks_.activation_requested) {
    callbacks_.activation_requested(callbacks_.opaque);
  }
}

void OrbitWebContentsHost::MediaStartedPlaying(
    const MediaPlayerInfo& media_info,
    const content::MediaPlayerId& id) {
  MediaPlayerEntry& entry = media_players_[id];
  entry.has_video = media_info.has_video;
  entry.is_playing = true;
  ReportPictureInPictureCandidateIfChanged();
}

void OrbitWebContentsHost::MediaStoppedPlaying(
    const MediaPlayerInfo& media_info,
    const content::MediaPlayerId& id,
    content::WebContentsObserver::MediaStoppedReason reason) {
  auto it = media_players_.find(id);
  if (it == media_players_.end()) {
    return;
  }
  it->second.has_video = media_info.has_video;
  it->second.is_playing = false;
  ReportPictureInPictureCandidateIfChanged();
}

void OrbitWebContentsHost::MediaMetadataChanged(
    const MediaPlayerInfo& media_info,
    const content::MediaPlayerId& id) {
  media_players_[id].has_video = media_info.has_video;
  ReportPictureInPictureCandidateIfChanged();
}

void OrbitWebContentsHost::MediaDestroyed(const content::MediaPlayerId& id) {
  media_players_.erase(id);
  ReportPictureInPictureCandidateIfChanged();
}

void OrbitWebContentsHost::PrimaryPageChanged(content::Page& page) {
  media_players_.clear();
  ClosePictureInPictureWindow(/*should_pause_video=*/false);
  ReportPictureInPictureCandidateIfChanged();
}

std::optional<content::MediaPlayerId>
OrbitWebContentsHost::PictureInPictureCandidate() const {
  std::optional<content::MediaPlayerId> idle;
  for (const auto& [id, entry] : media_players_) {
    if (!entry.has_video) {
      continue;
    }
    content::RenderFrameHost* render_frame_host =
        content::RenderFrameHost::FromID(id.frame_routing_id);
    if (!render_frame_host || !render_frame_host->IsRenderFrameLive()) {
      continue;
    }
    if (entry.is_playing) {
      return id;
    }
    if (!idle.has_value()) {
      idle = id;
    }
  }
  return idle;
}

bool OrbitWebContentsHost::HasPictureInPictureCandidate() {
  return PictureInPictureCandidate().has_value();
}

void OrbitWebContentsHost::ReportPictureInPictureCandidateIfChanged() {
  bool available = HasPictureInPictureCandidate();
  if (available == reported_picture_in_picture_candidate_) {
    return;
  }
  reported_picture_in_picture_candidate_ = available;
  if (callbacks_.picture_in_picture_available_changed) {
    callbacks_.picture_in_picture_available_changed(callbacks_.opaque, available ? 1 : 0);
  }
}

bool OrbitWebContentsHost::TogglePictureInPicture() {
  if (web_contents_->HasPictureInPictureVideo()) {
    ClosePictureInPictureWindow(/*should_pause_video=*/false);
    return true;
  }
  std::optional<content::MediaPlayerId> candidate = PictureInPictureCandidate();
  if (!candidate.has_value()) {
    return false;
  }
  content::RenderFrameHost* render_frame_host =
      content::RenderFrameHost::FromID(candidate->frame_routing_id);
  if (!render_frame_host || !render_frame_host->IsRenderFrameLive()) {
    return false;
  }
  // Without user activation the PiP request is refused outright, and the browser's only
  // other route (MediaSessionImpl) needs unmuted audio -- false for most of the web's video.
  render_frame_host->NotifyUserActivation(
      blink::mojom::UserActivationNotificationType::kInteraction);
  render_frame_host->ExecuteJavaScriptInIsolatedWorld(
      base::UTF8ToUTF16(std::string_view(kRequestPictureInPictureScript)),
      base::NullCallback(), kOrbitIsolatedWorldId);
  return true;
}

bool OrbitWebContentsHost::HasPictureInPictureVideo() {
  return web_contents_->HasPictureInPictureVideo();
}

void OrbitWebContentsHost::ApplyUserAgentOverride() {
  const std::string& ua = GlobalUserAgentOverride();
  web_contents_->SetUserAgentOverride(
      ua.empty() ? blink::UserAgentOverride() : blink::UserAgentOverride::UserAgentOnly(ua),
      /*override_in_new_tabs=*/!ua.empty());
}

// static
void OrbitWebContentsHost::SetGlobalUserAgentOverride(const std::string& user_agent) {
  GlobalUserAgentOverride() = user_agent;
  for (auto& [web_contents, host] : HostRegistry()) {
    host->ApplyUserAgentOverride();
  }
}

void OrbitWebContentsHost::PostMessage(const std::string& channel,
                                       const std::string& json) {
  if (callbacks_.did_receive_script_message) {
    callbacks_.did_receive_script_message(callbacks_.opaque, channel.c_str(),
                                          json.c_str());
  }
}

void OrbitWebContentsHost::BindScriptChannel(
    content::RenderFrameHost* render_frame_host,
    mojo::PendingAssociatedReceiver<mojom::ScriptChannel> receiver) {
  script_channel_receivers_->Bind(render_frame_host, std::move(receiver));
}

void OrbitWebContentsHost::DidStartLoading() {
  ReportNavigationState();
}

void OrbitWebContentsHost::DidStopLoading() {
  ReportNavigationState();
}

void OrbitWebContentsHost::LoadProgressChanged(double progress) {
  if (callbacks_.load_progress_changed) {
    callbacks_.load_progress_changed(callbacks_.opaque, progress);
  }
}

void OrbitWebContentsHost::TitleWasSet(content::NavigationEntry* entry) {
  if (!entry) {
    return;
  }
  // Independent of callbacks_.title_changed (may be unset before Swift attaches its
  // delegate): tabs.onUpdated must fire regardless of whether anything else is watching.
  OrbitTabRegistry::GetInstance().OnTabWebContentsStateChanged(web_contents_.get());
  if (!callbacks_.title_changed) {
    return;
  }
  const std::string title = base::UTF16ToUTF8(entry->GetTitle());
  callbacks_.title_changed(callbacks_.opaque, title.c_str());
}

void OrbitWebContentsHost::DidStartNavigation(
    content::NavigationHandle* navigation_handle) {
  OrbitWebNavigationEventRouter::DidStartNavigation(navigation_handle);
}

void OrbitWebContentsHost::DidFinishNavigation(
    content::NavigationHandle* navigation_handle) {
  // chrome.webNavigation covers every frame and same-document navigation;
  // the did_commit/did_finish/did_fail bridge below covers only the primary
  // main frame's cross-document loads (see the early return right after).
  OrbitWebNavigationEventRouter::DidFinishNavigation(navigation_handle);

  if (!navigation_handle->IsInPrimaryMainFrame() ||
      navigation_handle->IsSameDocument()) {
    return;
  }
  const std::string url = navigation_handle->GetURL().spec();

  // Without this, a same-icon-URL page reached twice (reload, back) would be deduplicated
  // against the previous document's icon and never re-download.
  reported_favicon_url_.clear();
  // Also abandons any download still in flight for the document being left,
  // which would otherwise report the old page's icon onto the new one.
  ++favicon_request_generation_;

  if (navigation_handle->HasCommitted() && !navigation_handle->IsErrorPage()) {
    if (callbacks_.did_commit) {
      int kind = PageTransitionToKind(navigation_handle->GetPageTransition(),
                                      navigation_handle->GetReloadType());
      callbacks_.did_commit(callbacks_.opaque, url.c_str(), kind);
    }
    if (callbacks_.did_finish) {
      const net::HttpResponseHeaders* headers =
          navigation_handle->GetResponseHeaders();
      int status_code = headers ? headers->response_code() : 0;
      callbacks_.did_finish(callbacks_.opaque, url.c_str(), status_code);
    }
    ReportNavigationState();
    ReportZoomFactorIfChanged();
    return;
  }

  if (callbacks_.did_fail) {
    net::Error error_code = navigation_handle->GetNetErrorCode();
    const std::string description =
        net::ErrorToString(static_cast<int>(error_code));
    callbacks_.did_fail(callbacks_.opaque, url.c_str(),
                        static_cast<int>(error_code), description.c_str());
  }
  ReportNavigationState();
}

void OrbitWebContentsHost::DOMContentLoaded(
    content::RenderFrameHost* render_frame_host) {
  OrbitWebNavigationEventRouter::DOMContentLoaded(web_contents_.get(), render_frame_host);
}

void OrbitWebContentsHost::DidFinishLoad(content::RenderFrameHost* render_frame_host,
                                         const GURL& validated_url) {
  OrbitWebNavigationEventRouter::DidFinishLoad(web_contents_.get(), render_frame_host,
                                               validated_url);
}

void OrbitWebContentsHost::DidFailLoad(content::RenderFrameHost* render_frame_host,
                                       const GURL& validated_url,
                                       int error_code) {
  OrbitWebNavigationEventRouter::DidFailLoad(web_contents_.get(), render_frame_host,
                                             validated_url, error_code);
}

void OrbitWebContentsHost::RenderFrameDeleted(
    content::RenderFrameHost* render_frame_host) {
  OrbitWebNavigationEventRouter::RenderFrameDeleted(web_contents_.get(), render_frame_host);
}

void OrbitWebContentsHost::RenderFrameCreated(
    content::RenderFrameHost* render_frame_host) {
  PushScriptsToFrame(render_frame_host);
  if (render_frame_host == web_contents_->GetPrimaryMainFrame()) {
    ApplyAutoResizeToMainFrame();
  }
}

void OrbitWebContentsHost::RenderFrameHostChanged(
    content::RenderFrameHost* old_host,
    content::RenderFrameHost* new_host) {
  // Initial main frame: RenderFrameCreated covers it, and new_host's renderer
  // frame does not exist yet -- mirrors views::WebView's own handling.
  if (!old_host) {
    return;
  }
  OrbitWebNavigationEventRouter::RenderFrameHostPendingDeletion(web_contents_.get(), old_host);
  ApplyAutoResizeToMainFrame();
}

void OrbitWebContentsHost::DidUpdateFaviconURL(
    content::RenderFrameHost* render_frame_host,
    const std::vector<blink::mojom::FaviconURLPtr>& candidates,
    blink::mojom::FaviconUpdateReason reason) {
  if (!render_frame_host ||
      render_frame_host != web_contents_->GetPrimaryMainFrame()) {
    return;
  }

  std::vector<const blink::mojom::FaviconURL*> usable;
  for (const auto& candidate : candidates) {
    if (!candidate || !candidate->icon_url.is_valid() ||
        FaviconCandidateScore(*candidate) < 0) {
      continue;
    }
    usable.push_back(candidate.get());
  }
  if (usable.empty()) {
    return;
  }
  // Stable, so equal-scoring candidates keep the order blink supplied them in
  // (measured: last-declared first) rather than an arbitrary one. Which end
  // that is matters less than it being the same every time.
  std::stable_sort(usable.begin(), usable.end(),
                   [](const blink::mojom::FaviconURL* lhs,
                      const blink::mojom::FaviconURL* rhs) {
                     return FaviconCandidateScore(*lhs) >
                            FaviconCandidateScore(*rhs);
                   });

  if (usable.front()->icon_url.spec() == reported_favicon_url_) {
    return;
  }
  reported_favicon_url_ = usable.front()->icon_url.spec();
  ++favicon_request_generation_;

  std::vector<GURL> ordered;
  ordered.reserve(usable.size());
  for (const blink::mojom::FaviconURL* candidate : usable) {
    ordered.push_back(candidate->icon_url);
  }
  DownloadNextFaviconCandidate(favicon_request_generation_, std::move(ordered));
}

void OrbitWebContentsHost::DownloadNextFaviconCandidate(
    uint64_t generation,
    std::vector<GURL> remaining) {
  if (remaining.empty()) {
    return;
  }
  const GURL url = remaining.front();
  remaining.erase(remaining.begin());
  web_contents_->DownloadImage(
      url, /*is_favicon=*/true, gfx::Size(kFaviconPreferredEdge, kFaviconPreferredEdge),
      /*max_bitmap_size=*/kFaviconMaxEdge, /*bypass_cache=*/false,
      base::BindOnce(&OrbitWebContentsHost::OnFaviconDownloaded,
                     weak_factory_.GetWeakPtr(), generation,
                     std::move(remaining)));
}

void OrbitWebContentsHost::OnFaviconDownloaded(
    uint64_t generation,
    std::vector<GURL> remaining,
    int id,
    int http_status_code,
    const GURL& image_url,
    const std::vector<SkBitmap>& bitmaps,
    const std::vector<gfx::Size>& sizes) {
  // The document's icons changed, or it navigated, while this was in flight.
  if (generation != favicon_request_generation_) {
    return;
  }

  const SkBitmap* best = nullptr;
  for (const SkBitmap& bitmap : bitmaps) {
    if (bitmap.drawsNothing()) {
      continue;
    }
    if (!best || bitmap.width() > best->width()) {
      best = &bitmap;
    }
  }

  if (!best) {
    if (!remaining.empty()) {
      DownloadNextFaviconCandidate(generation, std::move(remaining));
      return;
    }
    // Nothing decoded anywhere: still report the URL, so Swift can fall back
    // to fetching it itself rather than being told nothing at all.
    ReportFavicon(image_url, nullptr);
    return;
  }
  ReportFavicon(image_url, best);
}

void OrbitWebContentsHost::ReportFavicon(const GURL& icon_url,
                                         const SkBitmap* bitmap) {
  if (!callbacks_.favicon_changed) {
    return;
  }
  const std::string url = icon_url.spec();
  if (!bitmap) {
    callbacks_.favicon_changed(callbacks_.opaque, url.c_str(), nullptr, 0, 0, 0);
    return;
  }

  const int32_t width = bitmap->width();
  const int32_t height = bitmap->height();
  const int32_t stride = width * 4;
  std::vector<uint8_t> pixels(static_cast<size_t>(stride) *
                              static_cast<size_t>(height));
  const SkImageInfo dst_info =
      SkImageInfo::Make(width, height, kRGBA_8888_SkColorType, kPremul_SkAlphaType);
  if (!bitmap->readPixels(dst_info, pixels.data(), stride, 0, 0)) {
    callbacks_.favicon_changed(callbacks_.opaque, url.c_str(), nullptr, 0, 0, 0);
    return;
  }
  callbacks_.favicon_changed(callbacks_.opaque, url.c_str(), pixels.data(),
                             width, height, stride);
}

content::WebContents* OrbitWebContentsHost::OpenURLFromTab(
    content::WebContents* source,
    const content::OpenURLParams& params,
    base::OnceCallback<void(content::NavigationHandle&)>
        navigation_handle_callback) {
  if (!web_contents_) {
    return nullptr;
  }

  switch (params.disposition) {
    // SWITCH_TO_TAB reaches an embedder that never told content:: about any
    // other tab, so the only tab it can mean is this one.
    case WindowOpenDisposition::CURRENT_TAB:
    case WindowOpenDisposition::SINGLETON_TAB:
    case WindowOpenDisposition::SWITCH_TO_TAB:
      break;

    case WindowOpenDisposition::NEW_FOREGROUND_TAB:
    case WindowOpenDisposition::NEW_BACKGROUND_TAB:
    case WindowOpenDisposition::NEW_POPUP:
    case WindowOpenDisposition::NEW_WINDOW:
    case WindowOpenDisposition::OFF_THE_RECORD:
    case WindowOpenDisposition::NEW_PICTURE_IN_PICTURE:
    case WindowOpenDisposition::NEW_SPLIT_VIEW:
      RequestNewContent(this, nullptr, params.url.spec(),
                        static_cast<int>(params.disposition),
                        params.user_gesture);
      return nullptr;

    // SAVE_TO_DISK arrives here only for a route content:: has already
    // decided is not a navigation; the download machinery owns it, not this.
    case WindowOpenDisposition::SAVE_TO_DISK:
    case WindowOpenDisposition::IGNORE_ACTION:
    case WindowOpenDisposition::UNKNOWN:
      return nullptr;
  }

  content::NavigationController::LoadURLParams load_params(params);
  load_params.override_user_agent = CurrentUserAgentOverrideOption();
  base::WeakPtr<content::NavigationHandle> handle =
      web_contents_->GetController().LoadURLWithParams(load_params);
  if (navigation_handle_callback && handle) {
    std::move(navigation_handle_callback).Run(*handle);
  }
  return web_contents_.get();
}

content::WebContents* OrbitWebContentsHost::AddNewContents(
    content::WebContents* source,
    std::unique_ptr<content::WebContents> new_contents,
    const GURL& target_url,
    WindowOpenDisposition disposition,
    const blink::mojom::WindowFeatures& window_features,
    bool user_gesture,
    bool* was_blocked) {
  content::WebContents* raw_contents = new_contents.get();
  auto* host = new OrbitWebContentsHost(std::move(new_contents));
  if (!RequestNewContent(this, host, target_url.spec(),
                         static_cast<int>(disposition), user_gesture)) {
    delete host;
    // Reported as blocked, not merely dropped: WebContentsImpl::
    // CreateNewWindow otherwise goes on to LoadURLWithParams on the
    // WebContents this just destroyed.
    if (was_blocked) {
      *was_blocked = true;
    }
    return nullptr;
  }
  return raw_contents;
}

void OrbitWebContentsHost::FindReply(content::WebContents* web_contents,
                                     int request_id,
                                     int number_of_matches,
                                     const gfx::Rect& selection_rect,
                                     int active_match_ordinal,
                                     bool final_update) {
  if (request_id != find_request_id_ || !callbacks_.find_result_changed) {
    return;
  }
  callbacks_.find_result_changed(callbacks_.opaque, active_match_ordinal,
                                 number_of_matches, final_update ? 1 : 0);
}

void OrbitWebContentsHost::ResizeDueToAutoResize(
    content::WebContents* web_contents,
    const gfx::Size& new_size) {
  if (!callbacks_.preferred_size_changed) {
    return;
  }
  callbacks_.preferred_size_changed(callbacks_.opaque, new_size.width(),
                                    new_size.height());
}

bool OrbitWebContentsHost::HandleContextMenu(
    content::RenderFrameHost& render_frame_host,
    const content::ContextMenuParams& params) {
  // Recorded even with no Swift callback installed: chrome.contextMenus is
  // still queryable from a test harness that presents no menu of its own.
  last_context_menu_params_ = params;
  last_context_menu_frame_id_ = render_frame_host.GetGlobalId();

  if (!callbacks_.show_context_menu) {
    return false;
  }

  base::ListValue suggestions;
  for (const std::u16string& suggestion : params.dictionary_suggestions) {
    suggestions.Append(base::UTF16ToUTF8(suggestion));
  }
  std::string suggestions_json;
  if (!base::JSONWriter::Write(suggestions, &suggestions_json)) {
    suggestions_json = "[]";
  }

  const std::string page_url = params.page_url.spec();
  const std::string frame_url = params.frame_url.spec();
  const std::string link_url = params.link_url.spec();
  const std::string unfiltered_link_url = params.unfiltered_link_url.spec();
  const std::string src_url = params.src_url.spec();
  const std::string title_text = base::UTF16ToUTF8(params.title_text);
  const std::string selection_text = base::UTF16ToUTF8(params.selection_text);
  const std::string misspelled_word = base::UTF16ToUTF8(params.misspelled_word);

  callbacks_.show_context_menu(
      callbacks_.opaque, page_url.c_str(), frame_url.c_str(),
      link_url.c_str(), unfiltered_link_url.c_str(), src_url.c_str(),
      title_text.c_str(), selection_text.c_str(),
      static_cast<int>(params.media_type), params.is_editable ? 1 : 0,
      misspelled_word.c_str(), suggestions_json.c_str(), params.x, params.y);
  return true;
}

void OrbitWebContentsHost::OnGlobalUserScriptsChanged() {
  PushScriptsToAllFrames();
}

void OrbitWebContentsHost::ReportNavigationState() {
  OrbitTabRegistry::GetInstance().OnTabWebContentsStateChanged(web_contents_.get());
  if (!callbacks_.navigation_state_changed) {
    return;
  }
  const std::string url = web_contents_->GetVisibleURL().spec();
  callbacks_.navigation_state_changed(
      callbacks_.opaque, web_contents_->IsLoading() ? 1 : 0,
      CanGoBack() ? 1 : 0, CanGoForward() ? 1 : 0, url.c_str());
}

std::vector<UserScriptSpec> OrbitWebContentsHost::MergedScripts() const {
  std::vector<UserScriptSpec> merged = OrbitUserScriptRegistry::Get().global_scripts();
  merged.reserve(merged.size() + local_scripts_.size());
  for (const auto& [id, spec] : local_scripts_) {
    merged.push_back(spec);
  }
  return merged;
}

void OrbitWebContentsHost::PushScriptsToFrame(
    content::RenderFrameHost* render_frame_host) {
  if (!render_frame_host || !render_frame_host->IsRenderFrameLive()) {
    return;
  }
  mojo::AssociatedRemote<mojom::UserScriptInjector> remote;
  render_frame_host->GetRemoteAssociatedInterfaces()->GetInterface(&remote);
  remote->SetUserScripts(ToMojom(MergedScripts()));
}

void OrbitWebContentsHost::PushScriptsToAllFrames() {
  web_contents_->ForEachRenderFrameHost(
      [this](content::RenderFrameHost* rfh) { PushScriptsToFrame(rfh); });
}

void OrbitWebContentsHost::ReportZoomFactorIfChanged() {
  const double level = content::HostZoomMap::GetZoomLevel(web_contents_.get());
  if (has_reported_zoom_level_ && level == last_reported_zoom_level_) {
    return;
  }
  has_reported_zoom_level_ = true;
  last_reported_zoom_level_ = level;
  if (callbacks_.zoom_factor_changed) {
    callbacks_.zoom_factor_changed(callbacks_.opaque, blink::ZoomLevelToZoomFactor(level));
  }
}

}  // namespace orbit
