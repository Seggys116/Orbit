// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_app_hooks_delegate.h"

#include "base/check.h"
#include "base/check_op.h"
#include "base/functional/bind.h"
#include "base/notreached.h"
#include "base/values.h"
#include "content/public/renderer/render_frame.h"
#include "content/public/renderer/v8_value_converter.h"
#include "extensions/common/extension.h"
#include "extensions/common/manifest.h"
#include "extensions/renderer/api_activity_logger.h"
#include "extensions/renderer/bindings/api_binding_types.h"
#include "extensions/renderer/bindings/api_request_handler.h"
#include "extensions/renderer/bindings/api_signature.h"
#include "extensions/renderer/dispatcher.h"
#include "extensions/renderer/extension_frame_helper.h"
#include "extensions/renderer/get_script_context.h"
#include "extensions/renderer/ipc_message_sender.h"
#include "extensions/renderer/renderer_extension_registry.h"
#include "extensions/renderer/script_context.h"
#include "gin/converter.h"
#include "gin/public/gin_embedders.h"
#include "third_party/blink/public/web/web_document.h"
#include "third_party/blink/public/web/web_local_frame.h"
#include "url/origin.h"

namespace orbit {

namespace {

using RequestResult = extensions::APIBindingHooks::RequestResult;

// chrome/common/extensions/extension_constants.h's extension_misc::kAppState*;
// that header is chrome/-layer, which Orbit's embedder does not depend on.
constexpr char kAppStateRunning[] = "running";
constexpr char kAppStateCannotRun[] = "cannot_run";
constexpr char kAppStateReadyToRun[] = "ready_to_run";

// Required to keep the native data property in "accessor" state even when
// user code assigns over it.
void EmptySetterCallback(v8::Local<v8::Name> name,
                         v8::Local<v8::Value> value,
                         const v8::PropertyCallbackInfo<v8::Boolean>& info) {}

}  // namespace

// static
void OrbitAppHooksDelegate::IsInstalledGetterCallback(
    v8::Local<v8::Name> property,
    const v8::PropertyCallbackInfo<v8::Value>& info) {
  v8::HandleScope handle_scope(info.GetIsolate());
  v8::Local<v8::Context> context =
      info.Holder()->GetCreationContextChecked(info.GetIsolate());
  extensions::ScriptContext* script_context =
      extensions::GetScriptContextFromV8Context(context);

  // Invalidated ScriptContext (e.g. the frame was removed): return undefined.
  if (!script_context) {
    return;
  }

  auto* hooks_delegate = static_cast<OrbitAppHooksDelegate*>(
      info.Data().As<v8::External>()->Value(gin::kAppHooksDelegateTag));
  extensions::APIActivityLogger::LogAPICall(
      hooks_delegate->ipc_sender_, context, "app.getIsInstalled",
      v8::LocalVector<v8::Value>(info.GetIsolate()));
  info.GetReturnValue().Set(hooks_delegate->GetIsInstalled(script_context));
}

OrbitAppHooksDelegate::OrbitAppHooksDelegate(
    extensions::Dispatcher* dispatcher,
    extensions::APIRequestHandler* request_handler,
    extensions::IPCMessageSender* ipc_sender)
    : dispatcher_(dispatcher),
      request_handler_(request_handler),
      ipc_sender_(ipc_sender) {}

OrbitAppHooksDelegate::~OrbitAppHooksDelegate() = default;

bool OrbitAppHooksDelegate::GetIsInstalled(
    extensions::ScriptContext* script_context) const {
  const extensions::Extension* extension = script_context->extension();
  return extension && extension->is_hosted_app() &&
         dispatcher_->IsExtensionActive(extension->id());
}

RequestResult OrbitAppHooksDelegate::HandleRequest(
    const std::string& method_name,
    const extensions::APISignature* signature,
    v8::Local<v8::Context> context,
    v8::LocalVector<v8::Value>* arguments,
    const extensions::APITypeReferenceMap& refs) {
  v8::Isolate* isolate = v8::Isolate::GetCurrent();
  v8::TryCatch try_catch(isolate);
  extensions::APISignature::V8ParseResult parse_result =
      signature->ParseArgumentsToV8(context, *arguments, refs);
  if (!parse_result.succeeded()) {
    if (try_catch.HasCaught()) {
      try_catch.ReThrow();
      return RequestResult(RequestResult::THROWN);
    }
    return RequestResult(RequestResult::INVALID_INVOCATION);
  }

  extensions::ScriptContext* script_context =
      extensions::GetScriptContextFromV8ContextChecked(context);

  RequestResult result(RequestResult::HANDLED);
  if (method_name == "app.getIsInstalled") {
    result.return_value =
        v8::Boolean::New(isolate, GetIsInstalled(script_context));
  } else if (method_name == "app.getDetails") {
    result.return_value = GetDetails(script_context);
  } else if (method_name == "app.runningState") {
    result.return_value =
        gin::StringToSymbol(isolate, GetRunningState(script_context));
  } else if (method_name == "app.installState") {
    DCHECK_EQ(1u, parse_result.arguments->size());
    DCHECK((*parse_result.arguments)[0]->IsFunction());
    extensions::APIRequestHandler::RequestDetails request_details =
        request_handler_->AddPendingRequest(
            context, extensions::binding::AsyncResponseType::kCallback,
            (*parse_result.arguments)[0].As<v8::Function>(),
            extensions::binding::ResultModifierFunction());
    GetInstallState(script_context, request_details.request_id);
  } else {
    NOTREACHED();
  }

  return result;
}

void OrbitAppHooksDelegate::InitializeTemplate(
    v8::Isolate* isolate,
    v8::Local<v8::ObjectTemplate> object_template,
    const extensions::APITypeReferenceMap& type_refs) {
  // This object outlives every context, so the `this` v8::External is safe.
  object_template->SetNativeDataProperty(
      gin::StringToSymbol(isolate, "isInstalled"),
      &OrbitAppHooksDelegate::IsInstalledGetterCallback, EmptySetterCallback,
      v8::External::New(isolate, this, gin::kAppHooksDelegateTag));
}

v8::Local<v8::Value> OrbitAppHooksDelegate::GetDetails(
    extensions::ScriptContext* script_context) const {
  blink::WebLocalFrame* web_frame = script_context->web_frame();
  CHECK(web_frame);

  v8::Isolate* isolate = script_context->isolate();
  if (web_frame->GetDocument().GetSecurityOrigin().IsOpaque()) {
    return v8::Null(isolate);
  }

  const extensions::Extension* extension =
      extensions::RendererExtensionRegistry::Get()->GetExtensionOrAppByURL(
          web_frame->GetDocument().Url());

  if (!extension) {
    return v8::Null(isolate);
  }

  base::DictValue manifest_copy = extension->manifest()->value()->Clone();
  manifest_copy.Set("id", extension->id());
  return content::V8ValueConverter::Create()->ToV8Value(
      manifest_copy, script_context->v8_context());
}

void OrbitAppHooksDelegate::GetInstallState(
    extensions::ScriptContext* script_context,
    int request_id) {
  content::RenderFrame* render_frame = script_context->GetRenderFrame();
  CHECK(render_frame);

  extensions::ExtensionFrameHelper::Get(render_frame)
      ->GetLocalFrameHost()
      ->GetAppInstallState(
          script_context->web_frame()->GetDocument().Url(),
          base::BindOnce(&OrbitAppHooksDelegate::OnAppInstallStateResponse,
                         weak_factory_.GetWeakPtr(), request_id));
}

const char* OrbitAppHooksDelegate::GetRunningState(
    extensions::ScriptContext* script_context) const {
  // Inside a fenced frame tree the top security origin is meaningless.
  if (script_context->web_frame()->IsInFencedFrameTree()) {
    return kAppStateCannotRun;
  }

  const extensions::RendererExtensionRegistry* extensions =
      extensions::RendererExtensionRegistry::Get();

  url::Origin top_origin =
      script_context->web_frame()->Top()->GetSecurityOrigin();
  const extensions::Extension* top_app =
      extensions->GetHostedAppByURL(top_origin.GetURL());

  const extensions::Extension* this_app = extensions->GetHostedAppByURL(
      script_context->web_frame()->GetDocument().Url());

  if (!this_app || !top_app) {
    return kAppStateCannotRun;
  }

  const char* state = nullptr;
  if (dispatcher_->IsExtensionActive(top_app->id())) {
    if (top_app == this_app) {
      state = kAppStateRunning;
    } else {
      state = kAppStateCannotRun;
    }
  } else if (top_app == this_app) {
    state = kAppStateReadyToRun;
  } else {
    state = kAppStateCannotRun;
  }

  return state;
}

void OrbitAppHooksDelegate::OnAppInstallStateResponse(
    int request_id,
    const std::string& state) {
  base::ListValue response;
  response.Append(state);
  request_handler_->CompleteRequest(request_id, response, std::string());
}

}  // namespace orbit
