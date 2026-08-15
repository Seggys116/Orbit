// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_load_times_bindings.h"

#include <string>
#include <string_view>

#include "base/check.h"
#include "base/time/time.h"
#include "content/public/renderer/chrome_object_extensions_utils.h"
#include "net/http/http_connection_info.h"
#include "third_party/blink/public/platform/web_url_response.h"
#include "third_party/blink/public/web/web_document_loader.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_navigation_type.h"
#include "third_party/blink/public/web/web_performance_metrics_for_reporting.h"
#include "v8/include/v8-context.h"
#include "v8/include/v8-microtask-queue.h"
#include "v8/include/v8-function.h"
#include "v8/include/v8-object.h"
#include "v8/include/v8-primitive.h"

namespace orbit {

namespace {

// Values for CSI "tran" property -- see chrome/renderer/loadtimes_bindings.cc.
constexpr int kTransitionLink = 0;
constexpr int kTransitionForwardBack = 6;
constexpr int kTransitionOther = 15;
constexpr int kTransitionReload = 16;

std::string_view NavigationTypeToString(blink::WebNavigationType nav_type) {
  switch (nav_type) {
    case blink::kWebNavigationTypeLinkClicked:
      return "LinkClicked";
    case blink::kWebNavigationTypeFormSubmitted:
      return "FormSubmitted";
    case blink::kWebNavigationTypeBackForward:
    case blink::kWebNavigationTypeRestore:
      return "BackForward";
    case blink::kWebNavigationTypeReload:
      return "Reload";
    case blink::kWebNavigationTypeFormResubmittedBackForward:
    case blink::kWebNavigationTypeFormResubmittedReload:
      return "Resubmitted";
    case blink::kWebNavigationTypeOther:
      return "Other";
  }
  return "";
}

int NavigationTypeToCSITransition(blink::WebNavigationType nav_type) {
  switch (nav_type) {
    case blink::kWebNavigationTypeLinkClicked:
    case blink::kWebNavigationTypeFormSubmitted:
    case blink::kWebNavigationTypeFormResubmittedBackForward:
    case blink::kWebNavigationTypeFormResubmittedReload:
      return kTransitionLink;
    case blink::kWebNavigationTypeBackForward:
    case blink::kWebNavigationTypeRestore:
      return kTransitionForwardBack;
    case blink::kWebNavigationTypeReload:
      return kTransitionReload;
    case blink::kWebNavigationTypeOther:
      return kTransitionOther;
  }
  return kTransitionOther;
}

v8::Local<v8::String> V8Str(v8::Isolate* isolate, std::string_view s) {
  return v8::String::NewFromUtf8(isolate, s.data(), v8::NewStringType::kNormal,
                                 static_cast<int>(s.length()))
      .ToLocalChecked();
}

// Mirrors chrome/renderer/loadtimes_bindings.cc's LoadTimesBindings::GetLoadTimes.
void LoadTimesCallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  blink::WebLocalFrame* frame = blink::WebLocalFrame::FrameForCurrentContext();
  if (!frame) {
    info.GetReturnValue().SetNull();
    return;
  }
  blink::WebDocumentLoader* document_loader = frame->GetDocumentLoader();
  if (!document_loader) {
    info.GetReturnValue().SetNull();
    return;
  }

  const blink::WebURLResponse& response = document_loader->GetWebResponse();
  blink::WebPerformanceMetricsForReporting web_performance =
      frame->PerformanceMetricsForReporting();

  double request_time = web_performance.NavigationStart();
  double start_load_time = web_performance.NavigationStart();
  double commit_load_time = web_performance.ResponseStart();
  double finish_document_load_time =
      web_performance.DomContentLoadedEventEnd();
  double finish_load_time = web_performance.LoadEventEnd();
  double first_paint_time = web_performance.FirstPaint();
  // Chrome's own value, not ours -- see loadtimes_bindings.cc.
  double first_paint_after_load_time = 0.0;
  std::string_view navigation_type =
      NavigationTypeToString(document_loader->GetNavigationType());
  bool was_fetched_via_spdy = response.WasFetchedViaSPDY();
  bool was_alpn_negotiated = response.WasAlpnNegotiated();
  std::string alpn_negotiated_protocol =
      response.AlpnNegotiatedProtocol().Utf8();
  bool was_alternate_protocol_available =
      response.WasAlternateProtocolAvailable();
  std::string_view connection_info =
      net::HttpConnectionInfoToString(response.ConnectionInfo());

  // Chrome's per-field UseCounter sample is Blink-internal telemetry with no
  // JS-observable effect; not reproduced.
  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
  v8::Local<v8::Object> load_times = v8::Object::New(isolate);
  load_times
      ->Set(ctx, V8Str(isolate, "requestTime"),
           v8::Number::New(isolate, request_time))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "startLoadTime"),
           v8::Number::New(isolate, start_load_time))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "commitLoadTime"),
           v8::Number::New(isolate, commit_load_time))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "finishDocumentLoadTime"),
           v8::Number::New(isolate, finish_document_load_time))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "finishLoadTime"),
           v8::Number::New(isolate, finish_load_time))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "firstPaintTime"),
           v8::Number::New(isolate, first_paint_time))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "firstPaintAfterLoadTime"),
           v8::Number::New(isolate, first_paint_after_load_time))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "navigationType"),
           V8Str(isolate, navigation_type))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "wasFetchedViaSpdy"),
           v8::Boolean::New(isolate, was_fetched_via_spdy))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "wasNpnNegotiated"),
           v8::Boolean::New(isolate, was_alpn_negotiated))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "npnNegotiatedProtocol"),
           V8Str(isolate, alpn_negotiated_protocol))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "wasAlternateProtocolAvailable"),
           v8::Boolean::New(isolate, was_alternate_protocol_available))
      .Check();
  load_times
      ->Set(ctx, V8Str(isolate, "connectionInfo"),
           V8Str(isolate, connection_info))
      .Check();

  info.GetReturnValue().Set(load_times);
}

// Mirrors LoadTimesBindings::GetCSI.
void CSICallback(const v8::FunctionCallbackInfo<v8::Value>& info) {
  v8::Isolate* isolate = info.GetIsolate();
  blink::WebLocalFrame* frame = blink::WebLocalFrame::FrameForCurrentContext();
  if (!frame) {
    info.GetReturnValue().SetNull();
    return;
  }
  blink::WebDocumentLoader* document_loader = frame->GetDocumentLoader();
  if (!document_loader) {
    info.GetReturnValue().SetNull();
    return;
  }

  blink::WebPerformanceMetricsForReporting web_performance =
      frame->PerformanceMetricsForReporting();
  base::Time now = base::Time::Now();
  base::Time start =
      base::Time::FromSecondsSinceUnixEpoch(web_performance.NavigationStart());
  base::Time dom_content_loaded_end = base::Time::FromSecondsSinceUnixEpoch(
      web_performance.DomContentLoadedEventEnd());
  base::TimeDelta page = now - start;
  int navigation_type =
      NavigationTypeToCSITransition(document_loader->GetNavigationType());

  // Same UseCounter caveat as LoadTimesCallback above -- not reproduced.

  v8::Local<v8::Context> ctx = isolate->GetCurrentContext();
  v8::Local<v8::Object> csi = v8::Object::New(isolate);
  csi->Set(ctx, V8Str(isolate, "startE"),
          v8::Number::New(isolate, start.InMillisecondsSinceUnixEpoch()))
      .Check();
  csi->Set(ctx, V8Str(isolate, "onloadT"),
          v8::Number::New(isolate,
                          dom_content_loaded_end.InMillisecondsSinceUnixEpoch()))
      .Check();
  csi->Set(ctx, V8Str(isolate, "pageT"),
          v8::Number::New(isolate, page.InMillisecondsF()))
      .Check();
  csi->Set(ctx, V8Str(isolate, "tran"),
          v8::Number::New(isolate, navigation_type))
      .Check();

  info.GetReturnValue().Set(csi);
}

}  // namespace

void InstallLoadTimesBindings(v8::Local<v8::Context> context) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  DCHECK(isolate);
  v8::HandleScope handle_scope(isolate);
  if (context.IsEmpty()) {
    return;
  }
  v8::MicrotasksScope microtasks_scope(
      isolate, context->GetMicrotaskQueue(),
      v8::MicrotasksScope::kDoNotRunMicrotasks);
  v8::Context::Scope context_scope(context);

  v8::Local<v8::Object> chrome =
      content::GetOrCreateChromeObject(isolate, context);

  v8::Local<v8::Function> load_times_func;
  if (v8::Function::New(context, LoadTimesCallback).ToLocal(&load_times_func)) {
    chrome->Set(context, V8Str(isolate, "loadTimes"), load_times_func).Check();
  }

  v8::Local<v8::Function> csi_func;
  if (v8::Function::New(context, CSICallback).ToLocal(&csi_func)) {
    chrome->Set(context, V8Str(isolate, "csi"), csi_func).Check();
  }
}

}  // namespace orbit
