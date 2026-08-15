// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_command_service.h"

#include <memory>
#include <optional>
#include <utility>

#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/strings/utf_string_conversions.h"
#include "extensions/browser/event_router.h"
#include "extensions/common/api/commands/commands_handler.h"
#include "extensions/common/extension.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "ui/base/accelerators/command.h"

namespace orbit {

namespace {

OrbitExtensionCommandsCallback g_commands_callback = nullptr;
void* g_commands_opaque = nullptr;
OrbitExtensionActionActivatedCallback g_action_activated_callback = nullptr;
void* g_action_activated_opaque = nullptr;

// chrome/browser/extensions/extension_keybinding_registry.cc's own name.
constexpr char kOnCommandEventName[] = "commands.onCommand";

bool HasAccelerator(const ui::Command& command) {
  return command.accelerator().key_code() != ui::VKEY_UNKNOWN;
}

}  // namespace

// static
OrbitCommandService& OrbitCommandService::GetInstance() {
  static base::NoDestructor<OrbitCommandService> instance;
  return *instance;
}

OrbitCommandService::OrbitCommandService() = default;
OrbitCommandService::~OrbitCommandService() = default;

void OrbitCommandService::SetCommandsCallback(
    OrbitExtensionCommandsCallback callback, void* opaque) {
  g_commands_callback = callback;
  g_commands_opaque = opaque;
}

void OrbitCommandService::SetActionActivatedCallback(
    OrbitExtensionActionActivatedCallback callback, void* opaque) {
  g_action_activated_callback = callback;
  g_action_activated_opaque = opaque;
}

void OrbitCommandService::StartObserving(
    content::BrowserContext* browser_context) {
  if (!browser_context || registry_observation_.IsObserving()) {
    return;
  }
  browser_context_ = browser_context;
  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(browser_context);
  if (registry) {
    registry_observation_.Observe(registry);
  }
  Rebuild();
}

void OrbitCommandService::StopObserving() {
  registry_observation_.Reset();
  browser_context_ = nullptr;
  accelerators_.clear();
}

void OrbitCommandService::SetReservedAccelerators(
    const std::string& shortcuts_json) {
  reserved_.clear();
  std::optional<base::ListValue> parsed =
      base::JSONReader::ReadList(shortcuts_json, base::JSON_PARSE_RFC);
  if (parsed) {
    for (const base::Value& entry : *parsed) {
      const std::string* text = entry.GetIfString();
      if (!text || text->empty()) {
        continue;
      }
      // Parsed by Chromium's own accelerator parser so Orbit's reserved set and
      // an extension's suggested_key can never disagree about the syntax. The
      // ui:: overload, not the extensions:: one: it takes allow_ctrl_alt, so a
      // reserved Cmd+Option shortcut still parses and still reserves.
      ui::Accelerator accelerator = ui::Command::StringToAccelerator(*text);
      if (accelerator.key_code() != ui::VKEY_UNKNOWN) {
        reserved_.insert(accelerator);
      }
    }
  }
  Rebuild();
}

std::vector<ui::Command> OrbitCommandService::CollectDeclared(
    const extensions::Extension& extension) const {
  std::vector<ui::Command> declared;
  // getAll()'s own order: browser action, action, page action, then the named
  // commands in map order. See chrome/browser/extensions/api/commands/
  // commands.cc's CommandsGetAllFunction::Run.
  const extensions::Command* action_commands[] = {
      extensions::CommandsInfo::GetBrowserActionCommand(&extension),
      extensions::CommandsInfo::GetActionCommand(&extension),
      extensions::CommandsInfo::GetPageActionCommand(&extension),
  };
  for (const extensions::Command* command : action_commands) {
    if (command) {
      declared.push_back(*command);
    }
  }
  const ui::CommandMap* named =
      extensions::CommandsInfo::GetNamedCommands(&extension);
  if (named) {
    for (const auto& entry : *named) {
      declared.push_back(entry.second);
    }
  }
  return declared;
}

bool OrbitCommandService::IsActive(const std::string& extension_id,
                                   const ui::Command& command) const {
  if (!HasAccelerator(command)) {
    return false;
  }
  auto it = accelerators_.find(command.accelerator());
  return it != accelerators_.end() &&
         it->second.extension_id == extension_id &&
         it->second.command_name == command.command_name();
}

void OrbitCommandService::Rebuild() {
  accelerators_.clear();
  extensions::ExtensionRegistry* registry =
      browser_context_ ? extensions::ExtensionRegistry::Get(browser_context_)
                       : nullptr;
  if (registry) {
    for (const auto& extension : registry->enabled_extensions()) {
      for (const ui::Command& command : CollectDeclared(*extension)) {
        if (!HasAccelerator(command)) {
          continue;
        }
        // Media keys reach AppKit as .systemDefined events, which Orbit's
        // .keyDown monitor never sees. Registering one would make getAll()
        // report a shortcut that can never fire, so it stays inactive.
        if (command.accelerator().IsMediaKey()) {
          continue;
        }
        // Orbit's own shortcuts win outright, and between two extensions the
        // first claimant wins -- CommandService refuses to auto-assign over
        // either (AddKeybindingPref with overwriting disallowed, plus the
        // IsChromeAccelerator check in CanAutoAssign).
        if (reserved_.contains(command.accelerator()) ||
            accelerators_.contains(command.accelerator())) {
          continue;
        }
        accelerators_[command.accelerator()] =
            Registration{extension->id(), command.command_name()};
      }
    }
  }
  Emit();
}

base::ListValue OrbitCommandService::GetCommandsForExtension(
    const extensions::Extension& extension) {
  base::ListValue list;
  for (const ui::Command& command : CollectDeclared(extension)) {
    const bool active = IsActive(extension.id(), command);
    base::DictValue value;
    value.Set("name", command.command_name());
    value.Set("description", base::UTF16ToUTF8(command.description()));
    value.Set("shortcut",
              base::UTF16ToUTF8(active
                                    ? command.accelerator().GetShortcutText()
                                    : std::u16string()));
    list.Append(std::move(value));
  }
  return list;
}

std::string OrbitCommandService::GetAllCommandsJSON() {
  base::ListValue list;
  extensions::ExtensionRegistry* registry =
      browser_context_ ? extensions::ExtensionRegistry::Get(browser_context_)
                       : nullptr;
  if (registry) {
    for (const auto& extension : registry->enabled_extensions()) {
      for (const ui::Command& command : CollectDeclared(*extension)) {
        const bool active = IsActive(extension->id(), command);
        base::DictValue value;
        value.Set("extensionId", extension->id());
        value.Set("name", command.command_name());
        value.Set("description", base::UTF16ToUTF8(command.description()));
        value.Set("accelerator",
                  ui::Command::AcceleratorToString(command.accelerator()));
        value.Set("shortcut",
                  base::UTF16ToUTF8(active
                                        ? command.accelerator().GetShortcutText()
                                        : std::u16string()));
        value.Set("global", command.global());
        value.Set("active", active);
        value.Set("isAction",
                  extensions::Command::IsActionRelatedCommand(
                      command.command_name()));
        list.Append(std::move(value));
      }
    }
  }
  std::string json;
  base::JSONWriter::Write(list, &json);
  return json;
}

bool OrbitCommandService::Dispatch(const std::string& extension_id,
                                   const std::string& command_name) {
  bool claimed = false;
  for (const auto& entry : accelerators_) {
    if (entry.second.extension_id == extension_id &&
        entry.second.command_name == command_name) {
      claimed = true;
      break;
    }
  }
  if (!claimed) {
    return false;
  }
  extensions::ExtensionRegistry* registry =
      browser_context_ ? extensions::ExtensionRegistry::Get(browser_context_)
                       : nullptr;
  const extensions::Extension* extension =
      registry ? registry->enabled_extensions().GetByID(extension_id) : nullptr;
  if (!extension) {
    return false;
  }

  // The reserved action commands trigger the extension's action instead of
  // firing onCommand -- ExtensionKeybindingRegistry::ShouldIgnoreCommand hands
  // exactly these to the browser UI. Orbit's toolbar and popup live in Swift,
  // so this relays there rather than opening anything itself.
  if (extensions::Command::IsActionRelatedCommand(command_name)) {
    if (!g_action_activated_callback) {
      return false;
    }
    g_action_activated_callback(g_action_activated_opaque,
                                extension_id.c_str());
    return true;
  }

  return DispatchNamedCommand(*extension, command_name);
}

bool OrbitCommandService::DispatchNamedCommand(
    const extensions::Extension& extension,
    const std::string& command_name) {
  extensions::EventRouter* event_router =
      browser_context_ ? extensions::EventRouter::Get(browser_context_)
                       : nullptr;
  // No listener means the key press is not consumed, so it still reaches the
  // page -- ExtensionKeybindingRegistry::ExecuteCommands skips the same way.
  if (!event_router || !event_router->ExtensionHasEventListener(
                           extension.id(), kOnCommandEventName)) {
    return false;
  }

  base::ListValue args;
  args.Append(command_name);

  // The active tab of the last-focused window, scrubbed per the extension's own
  // access. Upstream also grants activeTab here; Orbit has no
  // ActiveTabPermissionGranter at all, so nothing is granted -- see the header.
  base::Value tab_value;
  const OrbitTabRegistry& tabs = OrbitTabRegistry::GetInstance();
  const int32_t window_id = tabs.GetLastFocusedWindowId();
  for (const OrbitTabInfo* tab : tabs.GetAllTabs()) {
    if (tab->window_id == window_id && tab->active) {
      tab_value = base::Value(tabs.CreateTabValue(*tab, &extension));
      break;
    }
  }
  args.Append(std::move(tab_value));

  auto event = std::make_unique<extensions::Event>(
      extensions::events::COMMANDS_ON_COMMAND, kOnCommandEventName,
      std::move(args), browser_context_);
  event->user_gesture = extensions::EventRouter::UserGestureState::kEnabled;
  event_router->DispatchEventToExtension(extension.id(), std::move(event));
  return true;
}

void OrbitCommandService::Emit() {
  if (g_commands_callback) {
    const std::string json = GetAllCommandsJSON();
    g_commands_callback(g_commands_opaque, json.c_str());
  }
}

void OrbitCommandService::OnExtensionLoaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension) {
  Rebuild();
}

void OrbitCommandService::OnExtensionUnloaded(
    content::BrowserContext* browser_context,
    const extensions::Extension* extension,
    extensions::UnloadedExtensionReason reason) {
  Rebuild();
}

}  // namespace orbit
