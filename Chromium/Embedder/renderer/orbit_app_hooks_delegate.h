// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Renderer half of chrome.app; Orbit doesn't include
// ChromeExtensionsRendererAPIProvider, so this is ported from chrome's
// app_hooks_delegate.cc.

#ifndef ORBIT_EMBEDDER_RENDERER_ORBIT_APP_HOOKS_DELEGATE_H_
#define ORBIT_EMBEDDER_RENDERER_ORBIT_APP_HOOKS_DELEGATE_H_

#include <string>

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "extensions/renderer/bindings/api_binding_hooks_delegate.h"
#include "v8/include/v8.h"

namespace extensions {
class APIRequestHandler;
class Dispatcher;
class IPCMessageSender;
class ScriptContext;
}  // namespace extensions

namespace orbit {

class OrbitAppHooksDelegate : public extensions::APIBindingHooksDelegate {
 public:
  OrbitAppHooksDelegate(extensions::Dispatcher* dispatcher,
                        extensions::APIRequestHandler* request_handler,
                        extensions::IPCMessageSender* ipc_sender);
  OrbitAppHooksDelegate(const OrbitAppHooksDelegate&) = delete;
  OrbitAppHooksDelegate& operator=(const OrbitAppHooksDelegate&) = delete;
  ~OrbitAppHooksDelegate() override;

  // extensions::APIBindingHooksDelegate:
  extensions::APIBindingHooks::RequestResult HandleRequest(
      const std::string& method_name,
      const extensions::APISignature* signature,
      v8::Local<v8::Context> context,
      v8::LocalVector<v8::Value>* arguments,
      const extensions::APITypeReferenceMap& refs) override;
  void InitializeTemplate(
      v8::Isolate* isolate,
      v8::Local<v8::ObjectTemplate> object_template,
      const extensions::APITypeReferenceMap& type_refs) override;

  // Total misnomer, kept to match the chrome.app function it implements:
  // returns true if a hosted app associated with `script_context` is active in
  // this process.
  bool GetIsInstalled(extensions::ScriptContext* script_context) const;

 private:
  static void IsInstalledGetterCallback(
      v8::Local<v8::Name> property,
      const v8::PropertyCallbackInfo<v8::Value>& info);

  v8::Local<v8::Value> GetDetails(
      extensions::ScriptContext* script_context) const;
  void GetInstallState(extensions::ScriptContext* script_context,
                       int request_id);
  const char* GetRunningState(
      extensions::ScriptContext* script_context) const;
  void OnAppInstallStateResponse(int request_id, const std::string& state);

  const raw_ptr<extensions::Dispatcher> dispatcher_ = nullptr;
  const raw_ptr<extensions::APIRequestHandler> request_handler_ = nullptr;
  const raw_ptr<extensions::IPCMessageSender> ipc_sender_ = nullptr;

  base::WeakPtrFactory<OrbitAppHooksDelegate> weak_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_RENDERER_ORBIT_APP_HOOKS_DELEGATE_H_
