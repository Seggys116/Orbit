// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_loader.h"

#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/feature_list.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/scoped_observation.h"
#include "base/strings/utf_string_conversions.h"
#include "base/values.h"
#include "base/version.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "extensions/browser/api/runtime/runtime_api.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "extensions/browser/extension_file_task_runner.h"
#include "extensions/browser/extension_prefs.h"
#include "extensions/browser/extension_registrar.h"
#include "extensions/browser/extension_registry.h"
#include "extensions/browser/extension_system.h"
#include "extensions/browser/extension_user_script_loader.h"
#include "extensions/browser/extensions_browser_client.h"
#include "extensions/browser/unloaded_extension_reason.h"
#include "extensions/browser/unpacked_installer.h"
#include "extensions/browser/user_script_loader.h"
#include "extensions/browser/user_script_manager.h"
#include "extensions/common/api/extension_action/action_info.h"
#include "extensions/common/api/runtime.h"
#include "extensions/common/constants.h"
#include "extensions/common/extension.h"
#include "extensions/common/extension_features.h"
#include "extensions/common/file_util.h"
#include "extensions/common/icons/extension_icon_set.h"
#include "extensions/common/manifest.h"
#include "extensions/common/manifest_handlers/background_info.h"
#include "extensions/common/manifest_handlers/content_scripts_handler.h"
#include "extensions/common/manifest_handlers/icons_handler.h"
#include "extensions/common/mojom/manifest.mojom-shared.h"

namespace orbit {

namespace {

// Per-extension record of the last-loaded version, substituting for
// upstream's registry-based previousVersion source (Orbit unloads the
// running copy before every update, unlike Chrome). Decides install vs
// update vs re-registration below; cleared by DeleteExtensionPrefs.
constexpr char kOrbitLoadedVersion[] = "orbit_loaded_version";

// lazy_event_dispatch_util.cc's private pref keys, the only channel for
// telling DispatchOnInstalledEvent which version it replaces; corrected in
// OrbitExtensionRegistrarDelegate::PreAddExtension between write and read.
constexpr char kPendingOnInstalledInfo[] =
    "pending_on_installed_event_dispatch_info";
constexpr char kPendingPreviousVersion[] = "previous_version";

std::string GetRecordedVersion(content::BrowserContext* browser_context,
                               const extensions::ExtensionId& id) {
  std::string version;
  extensions::ExtensionPrefs::Get(browser_context)
      ->ReadPrefAsString(id, kOrbitLoadedVersion, &version);
  return version;
}

// ExtensionPrefs deliberately does not cache an unpacked extension's manifest,
// so GetInstalledExtensionInfo().extension_manifest is ALWAYS null here and
// GetVersionString() always empty -- kOrbitLoadedVersion above is what stands
// in for it, not a redundant duplicate of it.
void RecordVersion(content::BrowserContext* browser_context,
                   const extensions::Extension& extension) {
  extensions::ExtensionPrefs::Get(browser_context)
      ->UpdateExtensionPref(extension.id(), kOrbitLoadedVersion,
                            base::Value(extension.version().GetString()));
}

base::DictValue ExtensionToDict(const extensions::Extension& extension,
                                  bool is_enabled) {
  base::DictValue dict;
  dict.Set("id", extension.id());
  dict.Set("name", extension.name());
  dict.Set("version", extension.version().GetString());
  dict.Set("directory", extension.path().value());
  dict.Set("hasToolbarAction",
          extensions::ActionInfo::GetExtensionActionInfo(&extension) != nullptr);
  dict.Set("manifestVersion", extension.manifest_version());
  dict.Set("isEnabled", is_enabled);

  const std::string& icon_relative_path = extensions::IconsInfo::GetIcons(&extension).Get(
      extension_misc::EXTENSION_ICON_MEDIUM, ExtensionIconSet::Match::kBigger);
  dict.Set("iconPath", icon_relative_path.empty()
                          ? std::string()
                          : extension.path().AppendASCII(icon_relative_path).value());
  return dict;
}

std::string DictToJSON(base::DictValue dict) {
  std::string json;
  base::JSONWriter::Write(dict, &json);
  return json;
}

// UnpackedInstaller::GetFlags() for a profile that never turns file access
// off; Orbit exposes no such control, so this mirrors
// Manifest::ShouldAlwaysAllowFileAccess directly rather than reading the pref.
int UnpackedCreationFlags() {
  int flags = extensions::Extension::FOLLOW_SYMLINKS_ANYWHERE |
              extensions::Extension::REQUIRE_MODERN_MANIFEST_VERSION;
  if (extensions::Manifest::ShouldAlwaysAllowFileAccess(
          extensions::mojom::ManifestLocation::kUnpacked)) {
    flags |= extensions::Extension::ALLOW_FILE_ACCESS;
  }
  if (base::FeatureList::IsEnabled(
          extensions_features::
              kAllowWithholdingExtensionPermissionsOnInstall)) {
    flags |= extensions::Extension::WITHHOLD_PERMISSIONS;
  }
  return flags;
}

struct DiskLoad {
  DiskLoad();
  DiskLoad(DiskLoad&&);
  DiskLoad& operator=(DiskLoad&&);
  ~DiskLoad();

  base::FilePath absolute_path;
  scoped_refptr<const extensions::Extension> extension;
  std::u16string error;
};

DiskLoad::DiskLoad() = default;
DiskLoad::DiskLoad(DiskLoad&&) = default;
DiskLoad& DiskLoad::operator=(DiskLoad&&) = default;
DiskLoad::~DiskLoad() = default;

// Reads only the manifest: the cheap identity probe deciding "put it back"
// vs "install it"; the install path still repeats UnpackedInstaller's
// illegal-filename/locale/DNR indexing work itself.
DiskLoad LoadFromDisk(const base::FilePath& directory, int creation_flags) {
  DiskLoad result;
  result.absolute_path = base::MakeAbsoluteFilePath(directory);
  if (result.absolute_path.empty() ||
      !base::PathExists(result.absolute_path)) {
    result.error = u"File path cannot be resolved.";
    return result;
  }
  result.extension = extensions::file_util::LoadExtension(
      result.absolute_path, extensions::mojom::ManifestLocation::kUnpacked,
      creation_flags, &result.error);
  return result;
}

// UnpackedInstaller reports success once the extension is registered, but
// UserScriptManager reads its content scripts asynchronously after that; a
// navigation issued right after this callback would silently lose them.
// Holds the callback until scripts are live, like upstream's
// ContentScriptLoadWaiter.
class ContentScriptLoadResponder : public extensions::UserScriptLoader::Observer {
 public:
  ContentScriptLoadResponder(extensions::ExtensionUserScriptLoader* loader,
                             std::string json,
                             OrbitLoadExtensionCallback callback,
                             void* callback_opaque)
      : json_(std::move(json)),
        callback_(callback),
        callback_opaque_(reinterpret_cast<uintptr_t>(callback_opaque)) {
    observation_.Observe(loader);
  }

  ContentScriptLoadResponder(const ContentScriptLoadResponder&) = delete;
  ContentScriptLoadResponder& operator=(const ContentScriptLoadResponder&) = delete;

  // Any completed round means scripts are published to every renderer.
  // Deliberately not gated on HasLoadedScripts(): an empty-list load still
  // finished, and treating that as "not yet" would wait forever.
  void OnScriptsLoaded(extensions::UserScriptLoader* loader,
                       content::BrowserContext* browser_context) override {
    Respond();
  }

  // Unloaded before scripts finished loading; a caller never hearing back
  // is worse than one told the extension loaded.
  void OnUserScriptLoaderDestroyed(extensions::UserScriptLoader* loader) override {
    Respond();
  }

 private:
  ~ContentScriptLoadResponder() override = default;

  void Respond() {
    observation_.Reset();
    callback_(reinterpret_cast<void*>(callback_opaque_), 1, json_.c_str(), "");
    delete this;
  }

  std::string json_;
  OrbitLoadExtensionCallback callback_;
  // Not raw_ptr<void>: it's the caller's opaque token, freed by the callback
  // while this object is still alive, which the dangling-pointer detector
  // would fail the process over.
  uintptr_t callback_opaque_;
  base::ScopedObservation<extensions::UserScriptLoader,
                          extensions::UserScriptLoader::Observer>
      observation_{this};
};

void RespondWhenContentScriptsAreLive(content::BrowserContext* browser_context,
                                      const extensions::Extension& extension,
                                      OrbitLoadExtensionCallback callback,
                                      void* callback_opaque) {
  const bool is_enabled = extensions::ExtensionRegistry::Get(browser_context)
                              ->enabled_extensions()
                              .Contains(extension.id());
  std::string json = DictToJSON(ExtensionToDict(extension, is_enabled));

  // Nothing to wait for if disabled/blocked (GetUserScriptLoaderForExtension
  // CHECK-fails outside enabled_extensions()) or if it declares no scripts.
  extensions::ExtensionSystem* system =
      extensions::ExtensionSystem::Get(browser_context);
  extensions::UserScriptManager* user_script_manager =
      system ? system->user_script_manager() : nullptr;
  if (!user_script_manager || !is_enabled ||
      extensions::ContentScriptsInfo::GetContentScripts(&extension).empty()) {
    callback(callback_opaque, 1, json.c_str(), "");
    return;
  }

  extensions::ExtensionUserScriptLoader* loader =
      user_script_manager->GetUserScriptLoaderForExtension(extension.id());
  if (loader->HasLoadedScripts()) {
    callback(callback_opaque, 1, json.c_str(), "");
    return;
  }

  new ContentScriptLoadResponder(loader, std::move(json), callback,
                                 callback_opaque);
}

// runtime.onStartup, which Orbit otherwise never fires: upstream's latch
// (ExtensionSystem::ready()) closes before Swift's bootstrap pass loads
// anything, so the embedder dispatches it manually for restored extensions.
// `after_install`: FinishExtensionInfoPrefs just wiped service worker event
// registrations for the new version, so ordinary dispatch finds no listener;
// route through DispatchEventWithLazyListener like onInstalled does. Skipped
// for a persistent background page, which registers for real at load time.
void DispatchOnStartup(content::BrowserContext* browser_context,
                       const extensions::Extension& extension,
                       bool after_install) {
  if (!after_install ||
      !extensions::BackgroundInfo::HasLazyContext(&extension)) {
    extensions::RuntimeEventRouter::DispatchOnStartupEvent(browser_context,
                                                           extension.id());
    return;
  }
  extensions::EventRouter::Get(browser_context)
      ->DispatchEventWithLazyListener(
          extension.id(),
          std::make_unique<extensions::Event>(
              extensions::events::RUNTIME_ON_STARTUP,
              extensions::api::runtime::OnStartup::kEventName,
              base::ListValue()));
}

void OnUnpackedInstallComplete(content::BrowserContext* browser_context,
                               bool dispatch_on_startup,
                               OrbitLoadExtensionCallback callback,
                               void* callback_opaque,
                               const extensions::Extension* extension,
                               const base::FilePath& file_path,
                               const std::u16string& error) {
  if (!callback) {
    return;
  }
  if (!extension) {
    callback(callback_opaque, 0, "", base::UTF16ToUTF8(error).c_str());
    return;
  }
  RecordVersion(browser_context, *extension);
  if (dispatch_on_startup) {
    DispatchOnStartup(browser_context, *extension, /*after_install=*/true);
  }
  RespondWhenContentScriptsAreLive(browser_context, *extension, callback,
                                   callback_opaque);
}

void StartUnpackedInstall(content::BrowserContext* browser_context,
                          const base::FilePath& directory,
                          bool dispatch_on_startup,
                          OrbitLoadExtensionCallback callback,
                          void* callback_opaque) {
  scoped_refptr<extensions::UnpackedInstaller> installer =
      extensions::UnpackedInstaller::Create(browser_context);
  installer->set_completion_callback(base::BindOnce(
      &OnUnpackedInstallComplete, base::Unretained(browser_context),
      dispatch_on_startup, callback, callback_opaque));
  installer->Load(directory);
}

void OnManifestRead(content::BrowserContext* browser_context,
                    ExtensionLoadReason reason,
                    OrbitLoadExtensionCallback callback,
                    void* callback_opaque,
                    DiskLoad loaded) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  if (!extensions::ExtensionsBrowserClient::Get() ||
      !extensions::ExtensionsBrowserClient::Get()->IsValidContext(
          browser_context)) {
    if (callback) {
      callback(callback_opaque, 0, "", "browser is not ready yet");
    }
    return;
  }
  if (!loaded.extension) {
    // Let UnpackedInstaller produce the error: its message for a given
    // failure is the one every other Orbit surface already shows.
    StartUnpackedInstall(browser_context, loaded.absolute_path,
                         /*dispatch_on_startup=*/false, callback,
                         callback_opaque);
    return;
  }

  const bool is_startup = reason == ExtensionLoadReason::kBrowserStartup;
  const extensions::ExtensionId id = loaded.extension->id();
  const bool known_to_prefs =
      extensions::ExtensionPrefs::Get(browser_context)
          ->GetInstalledExtensionInfo(id)
          .has_value();

  if (!known_to_prefs) {
    // Never installed in this profile: a genuine first install. onInstalled
    // fires "install"; onStartup does not, since it didn't exist at launch.
    StartUnpackedInstall(browser_context, loaded.absolute_path,
                         /*dispatch_on_startup=*/false, callback,
                         callback_opaque);
    return;
  }

  // Prefs exist but no recorded version predates kOrbitLoadedVersion: not a
  // new install or an update, so it takes the re-registration path below.
  const base::Version recorded(GetRecordedVersion(browser_context, id));
  if (recorded.IsValid() && recorded != loaded.extension->version()) {
    StartUnpackedInstall(browser_context, loaded.absolute_path, is_startup,
                         callback, callback_opaque);
    return;
  }

  // Already installed, same version: a startup load, re-enable or reload of
  // unchanged bytes, none an installation. AddExtension (not UnpackedInstaller,
  // which would wipe service worker state and fire onInstalled every time) is
  // the path upstream's InstalledLoader takes for exactly this case.
  extensions::ExtensionRegistrar* registrar =
      extensions::ExtensionRegistrar::Get(browser_context);
  extensions::ExtensionPrefs::Get(browser_context)
      ->UpdateManifest(loaded.extension.get());
  registrar->AddExtension(loaded.extension);

  extensions::ExtensionRegistry* registry =
      extensions::ExtensionRegistry::Get(browser_context);
  const bool enabled = registry->enabled_extensions().Contains(id);
  if (!enabled && !registry->disabled_extensions().Contains(id)) {
    if (callback) {
      callback(callback_opaque, 0, "",
               "extension could not be added to the registry");
    }
    return;
  }

  RecordVersion(browser_context, *loaded.extension);
  if (is_startup && enabled) {
    // Nothing was installed, so persisted registrations are intact and
    // upstream's dispatcher is correct; forcing a listener would wake a
    // worker that never asked for onStartup, which Chrome does not do.
    DispatchOnStartup(browser_context, *loaded.extension,
                      /*after_install=*/false);
  }
  if (callback) {
    RespondWhenContentScriptsAreLive(browser_context, *loaded.extension,
                                     callback, callback_opaque);
  }
}

}  // namespace

void RestorePreviousVersionForOnInstalled(
    content::BrowserContext* browser_context,
    const extensions::Extension& extension) {
  extensions::ExtensionPrefs* prefs =
      extensions::ExtensionPrefs::Get(browser_context);
  // No pending info means this add is not part of an installation at all, and
  // nothing is going to read this.
  if (!prefs->ReadPrefAsDict(extension.id(), kPendingOnInstalledInfo)) {
    return;
  }
  const base::Version recorded(
      GetRecordedVersion(browser_context, extension.id()));
  if (!recorded.IsValid() || recorded == extension.version()) {
    return;
  }
  base::DictValue info;
  info.Set(kPendingPreviousVersion, recorded.GetString());
  prefs->UpdateExtensionPref(extension.id(), kPendingOnInstalledInfo,
                             base::Value(std::move(info)));
}

void LoadUnpackedExtension(content::BrowserContext* browser_context,
                          const std::string& directory_path,
                          ExtensionLoadReason reason,
                          OrbitLoadExtensionCallback callback,
                          void* callback_opaque) {
  if (!browser_context) {
    if (callback) {
      callback(callback_opaque, 0, "", "browser is not ready yet");
    }
    return;
  }
  extensions::GetExtensionFileTaskRunner()->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(&LoadFromDisk, base::FilePath(directory_path),
                     UnpackedCreationFlags()),
      base::BindOnce(&OnManifestRead, base::Unretained(browser_context), reason,
                     callback, callback_opaque));
}

void UnloadExtension(content::BrowserContext* browser_context,
                     const std::string& extension_id) {
  if (!browser_context) {
    return;
  }
  extensions::ExtensionRegistrar::Get(browser_context)
      ->RemoveExtension(extension_id, extensions::UnloadedExtensionReason::UNINSTALL);
}

void UninstallExtension(content::BrowserContext* browser_context,
                        const std::string& extension_id) {
  if (!browser_context) {
    return;
  }
  UnloadExtension(browser_context, extension_id);
  extensions::ExtensionPrefs::Get(browser_context)->DeleteExtensionPrefs(extension_id);
}

std::string GetLoadedExtensionsJSON(content::BrowserContext* browser_context) {
  base::ListValue list;
  if (browser_context) {
    extensions::ExtensionRegistry* registry =
        extensions::ExtensionRegistry::Get(browser_context);
    for (const auto& extension : registry->enabled_extensions()) {
      list.Append(ExtensionToDict(*extension, /*is_enabled=*/true));
    }
    for (const auto& extension : registry->disabled_extensions()) {
      list.Append(ExtensionToDict(*extension, /*is_enabled=*/false));
    }
  }
  std::string json;
  base::JSONWriter::Write(list, &json);
  return json;
}

}  // namespace orbit
