// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Renderer half of chrome.tabs.sendMessage/connect; Orbit doesn't include
// ChromeExtensionsRendererAPIProvider, so this is ported from chrome's tabs_hooks_delegate.cc (minus MV2 sendRequest).

#ifndef ORBIT_EMBEDDER_RENDERER_ORBIT_TABS_HOOKS_DELEGATE_H_
#define ORBIT_EMBEDDER_RENDERER_ORBIT_TABS_HOOKS_DELEGATE_H_

#include <string>

#include "base/memory/raw_ptr.h"
#include "extensions/renderer/bindings/api_binding_hooks_delegate.h"
#include "extensions/renderer/bindings/api_signature.h"
#include "v8/include/v8.h"

namespace extensions {
class NativeRendererMessagingService;
class ScriptContext;
}  // namespace extensions

namespace orbit {

class OrbitTabsHooksDelegate : public extensions::APIBindingHooksDelegate {
 public:
  explicit OrbitTabsHooksDelegate(
      extensions::NativeRendererMessagingService* messaging_service);
  OrbitTabsHooksDelegate(const OrbitTabsHooksDelegate&) = delete;
  OrbitTabsHooksDelegate& operator=(const OrbitTabsHooksDelegate&) = delete;
  ~OrbitTabsHooksDelegate() override;

  // extensions::APIBindingHooksDelegate:
  extensions::APIBindingHooks::RequestResult HandleRequest(
      const std::string& method_name,
      const extensions::APISignature* signature,
      v8::Local<v8::Context> context,
      v8::LocalVector<v8::Value>* arguments,
      const extensions::APITypeReferenceMap& refs) override;

 private:
  extensions::APIBindingHooks::RequestResult HandleSendMessage(
      extensions::ScriptContext* script_context,
      const extensions::APISignature::V8ParseResult& parse_result);
  extensions::APIBindingHooks::RequestResult HandleConnect(
      extensions::ScriptContext* script_context,
      const extensions::APISignature::V8ParseResult& parse_result);

  // Owned by the NativeExtensionBindingsSystem that owns this delegate's
  // registry, so it outlives this object.
  const raw_ptr<extensions::NativeRendererMessagingService, DanglingUntriaged>
      messaging_service_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_RENDERER_ORBIT_TABS_HOOKS_DELEGATE_H_
