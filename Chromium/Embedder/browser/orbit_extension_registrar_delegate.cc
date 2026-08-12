// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extension_registrar_delegate.h"

#include "base/logging.h"
#include "base/values.h"
#include "components/sync/model/string_ordinal.h"
#include "extensions/browser/permissions/permissions_updater.h"
#include "extensions/common/extension.h"
#include "orbit/browser/orbit_extension_loader.h"

namespace orbit {

OrbitExtensionRegistrarDelegate::OrbitExtensionRegistrarDelegate(
    content::BrowserContext* browser_context)
    : browser_context_(browser_context) {}

OrbitExtensionRegistrarDelegate::~OrbitExtensionRegistrarDelegate() = default;

void OrbitExtensionRegistrarDelegate::SetExtensionRegistrar(
    extensions::ExtensionRegistrar* registrar) {
  extension_registrar_ = registrar;
}

// Required once a previously-installed extension comes back through plain
// ExtensionRegistrar::AddExtension instead of UnpackedInstaller: without this,
// a startup load would come up with no host/optional permissions restored.
void OrbitExtensionRegistrarDelegate::PreAddExtension(
    const extensions::Extension* extension,
    const extensions::Extension* old_extension) {
  extensions::PermissionsUpdater(browser_context_)
      .InitializePermissions(extension);
  // A null old_extension means the registry has no previous copy, exactly
  // when onInstalled would misreport an update as a fresh install.
  if (!old_extension) {
    RestorePreviousVersionForOnInstalled(browser_context_, *extension);
  }
}

void OrbitExtensionRegistrarDelegate::OnAddNewOrUpdatedExtension(
    const extensions::Extension* extension) {}

void OrbitExtensionRegistrarDelegate::PostActivateExtension(
    scoped_refptr<const extensions::Extension> extension) {}

void OrbitExtensionRegistrarDelegate::PostDeactivateExtension(
    scoped_refptr<const extensions::Extension> extension) {}

void OrbitExtensionRegistrarDelegate::PreUninstallExtension(
    scoped_refptr<const extensions::Extension> extension) {}

void OrbitExtensionRegistrarDelegate::PostUninstallExtension(
    scoped_refptr<const extensions::Extension> extension,
    base::OnceClosure done_callback) {
  // Orbit never deletes an unpacked extension's source directory -- it is
  // the developer's own files, loaded in place, not a copy Orbit owns.
  std::move(done_callback).Run();
}

void OrbitExtensionRegistrarDelegate::LoadExtensionForReload(
    const extensions::ExtensionId& extension_id,
    const base::FilePath& path) {
  LOG(WARNING) << "orbit: extension reload requested for " << extension_id
              << " but reload is not implemented yet";
}

void OrbitExtensionRegistrarDelegate::LoadExtensionForReloadWithQuietFailure(
    const extensions::ExtensionId& extension_id,
    const base::FilePath& path) {
  LoadExtensionForReload(extension_id, path);
}

void OrbitExtensionRegistrarDelegate::ShowExtensionDisabledError(
    const extensions::Extension* extension,
    bool is_remote_install) {
  LOG(WARNING) << "orbit: extension " << extension->id()
              << " was disabled after a permissions increase";
}

bool OrbitExtensionRegistrarDelegate::CanEnableExtension(
    const extensions::Extension* extension) {
  return true;
}

bool OrbitExtensionRegistrarDelegate::CanDisableExtension(
    const extensions::Extension* extension) {
  return true;
}

void OrbitExtensionRegistrarDelegate::GrantActivePermissions(
    const extensions::Extension* extension) {
  extensions::PermissionsUpdater(browser_context_)
      .GrantActivePermissions(extension);
}

void OrbitExtensionRegistrarDelegate::UpdateExternalExtensionAlert() {}

void OrbitExtensionRegistrarDelegate::OnExtensionInstalled(
    const extensions::Extension* extension,
    const syncer::StringOrdinal& page_ordinal,
    int install_flags,
    base::DictValue ruleset_install_prefs) {
  // No DelayedInstallManager install gates are registered (see
  // OrbitExtensionSystem), so every install completes immediately.
  extension_registrar_->AddNewOrUpdatedExtension(
      extension, install_flags, page_ordinal, /*install_parameter=*/std::string(),
      std::move(ruleset_install_prefs));
}

}  // namespace orbit
