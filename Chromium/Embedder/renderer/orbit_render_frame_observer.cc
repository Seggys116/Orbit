// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_render_frame_observer.h"

#include <utility>

#include "base/functional/bind.h"
#include "content/public/renderer/render_frame.h"
#include "gin/converter.h"
#include "gin/function_template.h"
#include "orbit/common/orbit_match_pattern.h"
#include "third_party/blink/public/common/associated_interfaces/associated_interface_provider.h"
#include "third_party/blink/public/platform/scheduler/web_agent_group_scheduler.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "third_party/blink/public/web/web_script_source.h"
#include "url/gurl.h"
#include "v8/include/v8-context.h"
#include "v8/include/v8-function.h"
#include "v8/include/v8-object.h"

namespace orbit {

OrbitRenderFrameObserver::OrbitRenderFrameObserver(
    content::RenderFrame* render_frame)
    : content::RenderFrameObserver(render_frame),
      content::RenderFrameObserverTracker<OrbitRenderFrameObserver>(
          render_frame) {
  associated_interfaces_.AddInterface<mojom::UserScriptInjector>(
      base::BindRepeating(&OrbitRenderFrameObserver::BindUserScriptInjector,
                          base::Unretained(this)));
}

OrbitRenderFrameObserver::~OrbitRenderFrameObserver() = default;

void OrbitRenderFrameObserver::OnDestruct() {
  delete this;
}

bool OrbitRenderFrameObserver::OnAssociatedInterfaceRequestForFrame(
    const std::string& interface_name,
    mojo::ScopedInterfaceEndpointHandle* handle) {
  return associated_interfaces_.TryBindInterface(interface_name, handle);
}

void OrbitRenderFrameObserver::BindUserScriptInjector(
    mojo::PendingAssociatedReceiver<mojom::UserScriptInjector> receiver) {
  // reset() first: a second push to a still-live frame binds while the first
  // receiver is still bound, tripping AssociatedReceiver's !is_bound() DCHECK.
  receiver_.reset();
  receiver_.Bind(std::move(receiver));
}

void OrbitRenderFrameObserver::SetUserScripts(
    std::vector<mojom::UserScriptSpecPtr> scripts) {
  scripts_.clear();
  scripts_.reserve(scripts.size());
  for (const mojom::UserScriptSpecPtr& wire : scripts) {
    UserScriptSpec spec;
    spec.id = wire->id;
    spec.is_stylesheet = wire->kind == mojom::UserScriptKind::kStylesheet;
    spec.source = wire->source;
    spec.document_start =
        wire->injection_time == mojom::UserScriptInjectionTime::kDocumentStart;
    spec.match_patterns = wire->match_patterns;
    spec.all_frames = wire->all_frames;
    scripts_.push_back(std::move(spec));
  }
}

void OrbitRenderFrameObserver::HandlePostMessage(const std::string& channel,
                                                 const std::string& json) {
  if (!render_frame()) {
    return;
  }
  if (!script_channel_remote_.is_bound()) {
    render_frame()->GetRemoteAssociatedInterfaces()->GetInterface(
        &script_channel_remote_);
  }
  script_channel_remote_->PostMessage(channel, json);
}

void OrbitRenderFrameObserver::DidClearWindowObject() {
  RunDocumentStartScripts();
}

void OrbitRenderFrameObserver::RunDocumentStartScripts() {
  if (scripts_.empty() || !render_frame()) {
    return;
  }
  blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
  if (!frame) {
    return;
  }
  const GURL url(frame->GetDocument().Url());
  const bool is_main_frame = render_frame()->IsMainFrame();

  bool installed_post_message = false;
  v8::Isolate* isolate = frame->GetAgentGroupScheduler()->Isolate();
  v8::HandleScope handle_scope(isolate);
  v8::Local<v8::Context> context = frame->MainWorldScriptContext();
  if (context.IsEmpty()) {
    return;
  }
  v8::Context::Scope context_scope(context);

  for (const UserScriptSpec& spec : scripts_) {
    if (!spec.document_start) {
      continue;
    }
    if (!spec.all_frames && !is_main_frame) {
      continue;
    }
    if (!MatchPatternsMatch(spec.match_patterns, url)) {
      continue;
    }

    if (spec.is_stylesheet) {
      frame->GetDocument().InsertStyleSheet(
          blink::WebString::FromUtf8(spec.source));
      continue;
    }

    if (!installed_post_message) {
      v8::Local<v8::Function> post_message =
          gin::CreateFunctionTemplate(
              isolate, base::BindRepeating(
                          &OrbitRenderFrameObserver::HandlePostMessage,
                          base::Unretained(this)))
              ->GetFunction(context)
              .ToLocalChecked();
      context->Global()
          ->Set(context, gin::StringToSymbol(isolate, "__orbitPostMessage"),
               post_message)
          .Check();
      installed_post_message = true;
    }

    frame->ExecuteScript(blink::WebScriptSource(
        blink::WebString::FromUtf8(spec.source), frame->GetDocument().Url()));
  }

  // Only a script that captured __orbitPostMessage during the loop above can
  // still reach it; page script running after this point cannot see it.
  if (installed_post_message) {
    context->Global()
        ->Delete(context, gin::StringToSymbol(isolate, "__orbitPostMessage"))
        .Check();
  }
}

void OrbitRenderFrameObserver::RunDocumentEndScripts() {
  if (scripts_.empty() || !render_frame()) {
    return;
  }
  blink::WebLocalFrame* frame = render_frame()->GetWebFrame();
  if (!frame) {
    return;
  }
  const GURL url(frame->GetDocument().Url());
  const bool is_main_frame = render_frame()->IsMainFrame();

  for (const UserScriptSpec& spec : scripts_) {
    if (spec.document_start) {
      continue;
    }
    if (!spec.all_frames && !is_main_frame) {
      continue;
    }
    if (!MatchPatternsMatch(spec.match_patterns, url)) {
      continue;
    }

    if (spec.is_stylesheet) {
      frame->GetDocument().InsertStyleSheet(
          blink::WebString::FromUtf8(spec.source));
    } else {
      frame->ExecuteScript(
          blink::WebScriptSource(blink::WebString::FromUtf8(spec.source),
                                 frame->GetDocument().Url()));
    }
  }
}

}  // namespace orbit
