// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extensions_renderer_api_provider.h"

#include <memory>

#include "base/dcheck_is_on.h"
#include "base/logging.h"
#include "base/notreached.h"
#include "base/strings/string_util.h"
#include "extensions/grit/extensions_renderer_generated_resources_map.h"
#include "extensions/grit/extensions_renderer_resources.h"
#include "extensions/renderer/bindings/api_bindings_system.h"
#include "extensions/renderer/native_extension_bindings_system.h"
#include "mojo/public/js/grit/mojo_bindings_resources.h"
#include "orbit/renderer/orbit_app_hooks_delegate.h"
#include "orbit/renderer/orbit_tabs_hooks_delegate.h"
#include "ui/base/resource/resource_bundle.h"
#include "ui/base/webui/resource_path.h"

namespace orbit {

namespace {

// Resources loaded by id from paks other than extensions_renderer_generated_resources.pak,
// which kExtensionsRendererGeneratedResources already covers.
constexpr webui::ResourcePath kOtherRendererResources[] = {
    {"mojo/public/js/mojo_bindings.js", IDR_MOJO_MOJO_BINDINGS_JS},
    {"extensions/renderer/resources/extension.css", IDR_EXTENSION_CSS},
};

void VerifyRendererResourcesArePacked() {
  const std::vector<std::string> missing =
      OrbitExtensionsRendererAPIProvider::FindUnpackedRendererResources();
  if (missing.empty()) {
    return;
  }

  const std::string detail = base::JoinString(missing, ", ");
  LOG(ERROR) << "orbit_resources.pak is missing " << missing.size()
             << " extensions renderer resource(s) that the module system "
                "registers by name: "
             << detail
             << ". Add the pak that produces them to "
                "repack(\"orbit_resources_pak\") in Chromium/Embedder/"
                "BUILD.gn -- otherwise the first extension to touch the "
                "matching API aborts its renderer process.";
#if DCHECK_IS_ON()
  NOTREACHED() << "Unpacked extensions renderer resources: " << detail;
#endif
}

}  // namespace

OrbitExtensionsRendererAPIProvider::OrbitExtensionsRendererAPIProvider() =
    default;
OrbitExtensionsRendererAPIProvider::~OrbitExtensionsRendererAPIProvider() =
    default;

// static
std::vector<std::string>
OrbitExtensionsRendererAPIProvider::FindUnpackedRendererResources() {
  const ui::ResourceBundle& bundle = ui::ResourceBundle::GetSharedInstance();
  std::vector<std::string> missing;
  for (const webui::ResourcePath& resource :
       kExtensionsRendererGeneratedResources) {
    if (bundle.GetRawDataResource(resource.id).empty()) {
      missing.emplace_back(resource.path);
    }
  }
  for (const webui::ResourcePath& resource : kOtherRendererResources) {
    if (bundle.GetRawDataResource(resource.id).empty()) {
      missing.emplace_back(resource.path);
    }
  }
  return missing;
}

void OrbitExtensionsRendererAPIProvider::RegisterNativeHandlers(
    extensions::ModuleSystem* module_system,
    extensions::NativeExtensionBindingsSystem* bindings_system,
    extensions::V8SchemaRegistry* v8_schema_registry,
    extensions::ScriptContext* context) const {
  core_.RegisterNativeHandlers(module_system, bindings_system,
                               v8_schema_registry, context);
}

void OrbitExtensionsRendererAPIProvider::AddBindingsSystemHooks(
    extensions::Dispatcher* dispatcher,
    extensions::NativeExtensionBindingsSystem* bindings_system) const {
  core_.AddBindingsSystemHooks(dispatcher, bindings_system);
  // Mirrors ChromeExtensionsRendererAPIProvider::AddBindingsSystemHooks's
  // own "tabs" registration -- without it tabs.sendMessage/tabs.connect are
  // simply absent from chrome.tabs. See orbit_tabs_hooks_delegate.h.
  extensions::APIBindingsSystem* bindings = bindings_system->api_system();
  bindings->RegisterHooksDelegate(
      "tabs", std::make_unique<OrbitTabsHooksDelegate>(
                  bindings_system->messaging_service()));
  // Mirrors ChromeExtensionsRendererAPIProvider's own "app" registration --
  // without it chrome.app is absent from every page. See
  // orbit_app_hooks_delegate.h.
  bindings->RegisterHooksDelegate(
      "app", std::make_unique<OrbitAppHooksDelegate>(
                 dispatcher, bindings->request_handler(),
                 bindings_system->GetIPCMessageSender()));
}

void OrbitExtensionsRendererAPIProvider::PopulateSourceMap(
    extensions::ResourceBundleSourceMap* source_map) const {
  core_.PopulateSourceMap(source_map);
  [[maybe_unused]] static const bool verified =
      (VerifyRendererResourcesArePacked(), true);
}

void OrbitExtensionsRendererAPIProvider::EnableCustomElementAllowlist() const {
  core_.EnableCustomElementAllowlist();
}

void OrbitExtensionsRendererAPIProvider::RequireWebViewModules(
    extensions::ScriptContext* context) const {
  core_.RequireWebViewModules(context);
}

}  // namespace orbit
