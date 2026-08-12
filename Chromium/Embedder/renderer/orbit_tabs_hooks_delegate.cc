// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_tabs_hooks_delegate.h"

#include <optional>
#include <string_view>
#include <utility>

#include "base/check_op.h"
#include "extensions/common/api/messaging/message.h"
#include "extensions/common/api/messaging/messaging_util.h"
#include "extensions/common/mojom/message_port.mojom-shared.h"
#include "extensions/renderer/api/messaging/gin_port.h"
#include "extensions/renderer/api/messaging/message_target.h"
#include "extensions/renderer/api/messaging/messaging_util.h"
#include "extensions/renderer/api/messaging/native_renderer_messaging_service.h"
#include "extensions/renderer/bindings/api_binding_types.h"
#include "extensions/renderer/get_script_context.h"
#include "extensions/renderer/script_context.h"
#include "gin/converter.h"

namespace orbit {

namespace {

using RequestResult = extensions::APIBindingHooks::RequestResult;

constexpr char kConnect[] = "tabs.connect";
constexpr char kSendMessage[] = "tabs.sendMessage";

}  // namespace

OrbitTabsHooksDelegate::OrbitTabsHooksDelegate(
    extensions::NativeRendererMessagingService* messaging_service)
    : messaging_service_(messaging_service) {}

OrbitTabsHooksDelegate::~OrbitTabsHooksDelegate() = default;

RequestResult OrbitTabsHooksDelegate::HandleRequest(
    const std::string& method_name,
    const extensions::APISignature* signature,
    v8::Local<v8::Context> context,
    v8::LocalVector<v8::Value>* arguments,
    const extensions::APITypeReferenceMap& refs) {
  using Handler = RequestResult (OrbitTabsHooksDelegate::*)(
      extensions::ScriptContext*,
      const extensions::APISignature::V8ParseResult&);
  static const struct {
    Handler handler;
    std::string_view method;
  } kHandlers[] = {
      {&OrbitTabsHooksDelegate::HandleSendMessage, kSendMessage},
      {&OrbitTabsHooksDelegate::HandleConnect, kConnect},
  };

  Handler handler = nullptr;
  for (const auto& handler_entry : kHandlers) {
    if (handler_entry.method == method_name) {
      handler = handler_entry.handler;
      break;
    }
  }
  if (!handler) {
    return RequestResult(RequestResult::NOT_HANDLED);
  }

  extensions::ScriptContext* script_context =
      extensions::GetScriptContextFromV8ContextChecked(context);

  extensions::APISignature::V8ParseResult parse_result =
      signature->ParseArgumentsToV8(context, *arguments, refs);
  if (!parse_result.succeeded()) {
    RequestResult result(RequestResult::INVALID_INVOCATION);
    result.error = std::move(*parse_result.error);
    return result;
  }

  return (this->*handler)(script_context, parse_result);
}

RequestResult OrbitTabsHooksDelegate::HandleSendMessage(
    extensions::ScriptContext* script_context,
    const extensions::APISignature::V8ParseResult& parse_result) {
  const v8::LocalVector<v8::Value>& arguments = *parse_result.arguments;
  DCHECK_EQ(4u, arguments.size());

  int tab_id = extensions::messaging_util::ExtractIntegerId(arguments[0]);
  extensions::messaging_util::MessageOptions options;
  if (!arguments[2]->IsNull()) {
    options = extensions::messaging_util::ParseMessageOptions(
        script_context->v8_context(), arguments[2].As<v8::Object>(),
        extensions::messaging_util::PARSE_FRAME_ID);
  }

  v8::Local<v8::Value> v8_message = arguments[1];
  DCHECK(!v8_message.IsEmpty());
  std::string error;

  extensions::mojom::ChannelType channel_type =
      extensions::mojom::ChannelType::kSendMessage;
  std::optional<extensions::Message> message =
      extensions::messaging_util::MessageFromV8(
          script_context->v8_context(), v8_message,
          extensions::messaging_util::GetSerializationFormat(
              script_context->extension(), channel_type),
          &error);
  if (!message) {
    RequestResult result(RequestResult::INVALID_INVOCATION);
    result.error = std::move(error);
    return result;
  }

  v8::Local<v8::Function> response_callback;
  if (!arguments[3]->IsNull()) {
    response_callback = arguments[3].As<v8::Function>();
  }

  v8::Local<v8::Promise> promise = messaging_service_->SendOneTimeMessage(
      script_context,
      extensions::MessageTarget::ForTab(tab_id, options.frame_id,
                                        options.document_id),
      channel_type, std::move(*message), parse_result.async_type,
      response_callback);

  RequestResult result(RequestResult::HANDLED);
  if (parse_result.async_type ==
      extensions::binding::AsyncResponseType::kPromise) {
    result.return_value = promise;
  }
  return result;
}

RequestResult OrbitTabsHooksDelegate::HandleConnect(
    extensions::ScriptContext* script_context,
    const extensions::APISignature::V8ParseResult& parse_result) {
  const v8::LocalVector<v8::Value>& arguments = *parse_result.arguments;
  DCHECK_EQ(2u, arguments.size());
  DCHECK_EQ(extensions::binding::AsyncResponseType::kNone,
            parse_result.async_type);

  int tab_id = extensions::messaging_util::ExtractIntegerId(arguments[0]);

  extensions::messaging_util::MessageOptions options;
  if (!arguments[1]->IsNull()) {
    options = extensions::messaging_util::ParseMessageOptions(
        script_context->v8_context(), arguments[1].As<v8::Object>(),
        extensions::messaging_util::PARSE_FRAME_ID |
            extensions::messaging_util::PARSE_CHANNEL_NAME);
  }

  extensions::GinPort* port = messaging_service_->Connect(
      script_context,
      extensions::MessageTarget::ForTab(tab_id, options.frame_id,
                                        options.document_id),
      options.channel_name,
      extensions::messaging_util::GetSerializationFormat(
          script_context->extension(),
          extensions::mojom::ChannelType::kConnect));
  DCHECK(port);

  RequestResult result(RequestResult::HANDLED);
  result.return_value =
      port->GetWrapper(script_context->isolate()).ToLocalChecked();
  return result;
}

}  // namespace orbit
