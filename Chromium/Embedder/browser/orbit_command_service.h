// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome/browser/extensions/commands/command_service.{h,cc} ported to an
// embedder with no chrome://extensions/shortcuts UI and no browser-side key
// handling: Orbit's Swift AppKit layer owns every real key press, so this
// class holds the accelerator table and decides which commands are active,
// but is driven by Swift rather than by a ui::AcceleratorTarget. Manifest
// parsing is entirely //extensions-core (CommandsHandler), unlike upstream
// where Command/CommandsInfo were chrome/-layer.
//
// Accelerators cross the bridge as Chromium's own canonical strings
// ("Command+Shift+Y") and are parsed back with Command::StringToAccelerator,
// so both sides agree on the syntax by construction.
//
// Two upstream behaviours Orbit cannot reach and does not fake: media-key
// commands never become active (Orbit's monitor sees only .keyDown), and a
// "global": true command is treated as a regular one, so it fires while Orbit
// is frontmost and not otherwise -- a real global hook needs an accessibility
// grant Orbit does not hold. Nor is activeTab granted before dispatch:
// //extensions ships ActiveTabPermissionGranter but nothing in Orbit creates
// one, so there is no grant to make, here or on a toolbar click.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_COMMAND_SERVICE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_COMMAND_SERVICE_H_

#include <map>
#include <set>
#include <string>
#include <utility>
#include <vector>

#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/scoped_observation.h"
#include "base/values.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_registry_observer.h"
#include "extensions/common/command.h"
#include "orbit/bridge/orbit_bridge_api.h"
#include "ui/base/accelerators/accelerator.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace extensions {
class Extension;
}  // namespace extensions

namespace orbit {

class OrbitCommandService : public extensions::ExtensionRegistryObserver {
 public:
  static OrbitCommandService& GetInstance();

  OrbitCommandService(const OrbitCommandService&) = delete;
  OrbitCommandService& operator=(const OrbitCommandService&) = delete;

  void SetCommandsCallback(OrbitExtensionCommandsCallback callback,
                           void* opaque);
  void SetActionActivatedCallback(
      OrbitExtensionActionActivatedCallback callback, void* opaque);

  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();

  // Accelerators Orbit's own UI owns, as a JSON array of canonical accelerator
  // strings. Replaces the whole set; every extension command matching one goes
  // inactive, mirroring CommandService::CanAutoAssign's IsChromeAccelerator().
  void SetReservedAccelerators(const std::string& shortcuts_json);

  // One entry per declared command of every enabled extension, active or not.
  std::string GetAllCommandsJSON();

  // A real key press Swift resolved to this command. False when the command is
  // not registered or not active, so a reserved accelerator can never fire even
  // if Swift asks.
  bool Dispatch(const std::string& extension_id,
                const std::string& command_name);

  // chrome.commands.getAll's payload for one extension.
  base::ListValue GetCommandsForExtension(
      const extensions::Extension& extension);

 private:
  friend class base::NoDestructor<OrbitCommandService>;

  struct Registration {
    std::string extension_id;
    std::string command_name;
  };

  OrbitCommandService();
  ~OrbitCommandService() override;

  // extensions::ExtensionRegistryObserver:
  void OnExtensionLoaded(content::BrowserContext* browser_context,
                         const extensions::Extension* extension) override;
  void OnExtensionUnloaded(content::BrowserContext* browser_context,
                           const extensions::Extension* extension,
                           extensions::UnloadedExtensionReason reason) override;

  // Rebuilt wholesale from the registry rather than patched: extension load and
  // unload are rare and the table is bounded by the manifests' own command
  // counts, and first-come-wins ordering has to be recomputed anyway.
  void Rebuild();
  void Emit();

  // Every declared command in getAll()'s order: action-related first, then
  // named commands.
  std::vector<ui::Command> CollectDeclared(
      const extensions::Extension& extension) const;

  // False when the manifest suggested no key, the key is reserved by Orbit, or
  // another extension claimed it first.
  bool IsActive(const std::string& extension_id,
                const ui::Command& command) const;

  bool DispatchNamedCommand(const extensions::Extension& extension,
                            const std::string& command_name);

  raw_ptr<content::BrowserContext> browser_context_ = nullptr;
  std::map<ui::Accelerator, Registration> accelerators_;
  std::set<ui::Accelerator> reserved_;

  base::ScopedObservation<extensions::ExtensionRegistry,
                          extensions::ExtensionRegistryObserver>
      registry_observation_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_COMMAND_SERVICE_H_
