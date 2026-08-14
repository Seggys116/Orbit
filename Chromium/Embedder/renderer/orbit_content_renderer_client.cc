// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_content_renderer_client.h"

#include "extensions/common/constants.h"
#include "extensions/renderer/dispatcher.h"
#include "extensions/renderer/extensions_renderer_client.h"
#include "media/base/audio_codecs.h"
#include "media/base/media_types.h"
#include "media/base/video_codecs.h"
#include "orbit/common/orbit_extensions_client.h"
#include "orbit/orbit_media_buildflags.h"
#include "orbit/renderer/orbit_extensions_renderer_api_provider.h"
#include "orbit/renderer/orbit_extensions_renderer_client.h"
#include "orbit/renderer/orbit_render_frame_observer.h"
#include "url/origin.h"

namespace orbit {

OrbitContentRendererClient::OrbitContentRendererClient() = default;
OrbitContentRendererClient::~OrbitContentRendererClient() = default;

void OrbitContentRendererClient::RenderThreadStarted() {
  // extensions::ExtensionsClient is a browser+renderer singleton; the browser
  // side sets it in OrbitContentBrowserClient's constructor.
  EnsureExtensionsClientInitialized();
  extensions_renderer_client_ = std::make_unique<OrbitExtensionsRendererClient>();
  extensions_renderer_client_->AddAPIProvider(
      std::make_unique<OrbitExtensionsRendererAPIProvider>());
  extensions_renderer_client_->RenderThreadStarted();
}

bool OrbitContentRendererClient::AllowScriptExtensionForServiceWorker(
    const url::Origin& script_origin) {
  return script_origin.scheme() == extensions::kExtensionScheme;
}

void OrbitContentRendererClient::WebViewCreated(
    blink::WebView* web_view,
    bool was_created_by_renderer,
    const url::Origin* outermost_origin) {
  extensions::ExtensionsRendererClient::Get()->WebViewCreated(web_view,
                                                              outermost_origin);
}

void OrbitContentRendererClient::RenderFrameCreated(
    content::RenderFrame* render_frame) {
  // Self-deleting: OrbitRenderFrameObserver::OnDestruct() runs when
  // render_frame is destroyed.
  auto* observer = new OrbitRenderFrameObserver(render_frame);
  extensions::ExtensionsRendererClient::Get()->RenderFrameCreated(
      render_frame, observer->extensions_binder_registry());
}

bool OrbitContentRendererClient::IsDecoderSupportedAudioType(
    const media::AudioType& type) {
  switch (type.codec) {
    case media::AudioCodec::kAAC:
#if !BUILDFLAG(ORBIT_BUNDLED_PROPRIETARY_DECODERS)
      // AudioToolbox is registered for xHE-AAC only; AAC-LC has no decoder.
      if (type.profile != media::AudioCodecProfile::kXHE_AAC) {
        return false;
      }
#endif
      break;
    case media::AudioCodec::kUnknown:
    case media::AudioCodec::kMP3:
    case media::AudioCodec::kPCM:
    case media::AudioCodec::kVorbis:
    case media::AudioCodec::kFLAC:
    case media::AudioCodec::kAMR_NB:
    case media::AudioCodec::kAMR_WB:
    case media::AudioCodec::kPCM_MULAW:
    case media::AudioCodec::kGSM_MS:
    case media::AudioCodec::kPCM_S16BE:
    case media::AudioCodec::kPCM_S24BE:
    case media::AudioCodec::kOpus:
    case media::AudioCodec::kEAC3:
    case media::AudioCodec::kPCM_ALAW:
    case media::AudioCodec::kALAC:
    case media::AudioCodec::kAC3:
    case media::AudioCodec::kMpegHAudio:
    case media::AudioCodec::kDTS:
    case media::AudioCodec::kDTSXP2:
    case media::AudioCodec::kDTSE:
    case media::AudioCodec::kAC4:
    case media::AudioCodec::kIAMF:
      break;
  }
  return content::ContentRendererClient::IsDecoderSupportedAudioType(type);
}

bool OrbitContentRendererClient::IsDecoderSupportedVideoType(
    const media::VideoType& type) {
  switch (type.codec) {
    case media::VideoCodec::kH264:
#if !BUILDFLAG(ORBIT_BUNDLED_PROPRIETARY_DECODERS)
      // VideoToolbox registers BASELINE..HIGH, with no software fallback.
      if (type.profile > media::H264PROFILE_HIGH) {
        return false;
      }
#endif
      break;
    case media::VideoCodec::kUnknown:
    case media::VideoCodec::kVC1:
    case media::VideoCodec::kMPEG2:
    case media::VideoCodec::kMPEG4:
    case media::VideoCodec::kTheora:
    case media::VideoCodec::kVP8:
    case media::VideoCodec::kVP9:
    case media::VideoCodec::kHEVC:
    case media::VideoCodec::kAV1:
    case media::VideoCodec::kDolbyVision:
      break;
  }
  return content::ContentRendererClient::IsDecoderSupportedVideoType(type);
}

void OrbitContentRendererClient::RunScriptsAtDocumentStart(
    content::RenderFrame* render_frame) {
  extensions::ExtensionsRendererClient::Get()->RunScriptsAtDocumentStart(render_frame);
}

void OrbitContentRendererClient::RunScriptsAtDocumentEnd(
    content::RenderFrame* render_frame) {
  // Not DidDispatchDOMContentLoadedEvent: content:: fires that inside a
  // ScriptForbiddenScope, so document-end scripts can't run there; use this hook instead.
  if (OrbitRenderFrameObserver* observer =
          OrbitRenderFrameObserver::Get(render_frame)) {
    observer->RunDocumentEndScripts();
  }
  extensions::ExtensionsRendererClient::Get()->RunScriptsAtDocumentEnd(render_frame);
}

void OrbitContentRendererClient::RunScriptsAtDocumentIdle(
    content::RenderFrame* render_frame) {
  extensions::ExtensionsRendererClient::Get()->RunScriptsAtDocumentIdle(render_frame);
}

void OrbitContentRendererClient::DidInitializeServiceWorkerContextOnWorkerThread(
    blink::WebServiceWorkerContextProxy* context_proxy,
    const GURL& service_worker_scope,
    const GURL& script_url) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->DidInitializeServiceWorkerContextOnWorkerThread(
          context_proxy, service_worker_scope, script_url);
}

void OrbitContentRendererClient::WillEvaluateServiceWorkerOnWorkerThread(
    blink::WebServiceWorkerContextProxy* context_proxy,
    v8::Local<v8::Context> v8_context,
    int64_t service_worker_version_id,
    const GURL& service_worker_scope,
    const GURL& script_url,
    const blink::ServiceWorkerToken& service_worker_token) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->WillEvaluateServiceWorkerOnWorkerThread(
          context_proxy, v8_context, service_worker_version_id,
          service_worker_scope, script_url, service_worker_token);
}

void OrbitContentRendererClient::DidStartServiceWorkerContextOnWorkerThread(
    int64_t service_worker_version_id,
    const GURL& service_worker_scope,
    const GURL& script_url,
    const blink::ServiceWorkerToken& service_worker_token) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->DidStartServiceWorkerContextOnWorkerThread(
          service_worker_version_id, service_worker_scope, script_url,
          service_worker_token);
}

void OrbitContentRendererClient::WillDestroyServiceWorkerContextOnWorkerThread(
    v8::Local<v8::Context> v8_context,
    int64_t service_worker_version_id,
    const GURL& service_worker_scope,
    const GURL& script_url,
    const blink::ServiceWorkerToken& service_worker_token) {
  extensions::ExtensionsRendererClient::Get()
      ->dispatcher()
      ->WillDestroyServiceWorkerContextOnWorkerThread(
          v8_context, service_worker_version_id, service_worker_scope,
          script_url, service_worker_token);
}

}  // namespace orbit
