// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_RENDERER_ORBIT_EXTENSIONS_RENDERER_API_PROVIDER_H_
#define ORBIT_EMBEDDER_RENDERER_ORBIT_EXTENSIONS_RENDERER_API_PROVIDER_H_

#include <string>
#include <vector>

#include "extensions/renderer/api/core_extensions_renderer_api_provider.h"
#include "extensions/renderer/extensions_renderer_api_provider.h"

namespace orbit {

// CoreExtensionsRendererAPIProvider plus a check that every renderer JS module
// registered by name actually resolves in orbit_resources.pak, else NOTREACHED aborts the renderer.
class OrbitExtensionsRendererAPIProvider
    : public extensions::ExtensionsRendererAPIProvider {
 public:
  OrbitExtensionsRendererAPIProvider();
  OrbitExtensionsRendererAPIProvider(
      const OrbitExtensionsRendererAPIProvider&) = delete;
  OrbitExtensionsRendererAPIProvider& operator=(
      const OrbitExtensionsRendererAPIProvider&) = delete;
  ~OrbitExtensionsRendererAPIProvider() override;

  // Resource paths registered with the module system but missing from the
  // loaded ui::ResourceBundle. Empty is the only healthy answer.
  static std::vector<std::string> FindUnpackedRendererResources();

  // extensions::ExtensionsRendererAPIProvider:
  void RegisterNativeHandlers(
      extensions::ModuleSystem* module_system,
      extensions::NativeExtensionBindingsSystem* bindings_system,
      extensions::V8SchemaRegistry* v8_schema_registry,
      extensions::ScriptContext* context) const override;
  void AddBindingsSystemHooks(
      extensions::Dispatcher* dispatcher,
      extensions::NativeExtensionBindingsSystem* bindings_system)
      const override;
  void PopulateSourceMap(
      extensions::ResourceBundleSourceMap* source_map) const override;
  void EnableCustomElementAllowlist() const override;
  void RequireWebViewModules(extensions::ScriptContext* context) const override;

 private:
  extensions::CoreExtensionsRendererAPIProvider core_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_RENDERER_ORBIT_EXTENSIONS_RENDERER_API_PROVIDER_H_
