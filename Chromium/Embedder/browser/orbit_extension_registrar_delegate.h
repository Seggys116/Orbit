// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// ExtensionRegistrar::Delegate for Orbit's single profile. Modelled on
// chrome_extension_registrar_delegate.h minus everything serving Chrome's
// sync engine, pending-extension manager, delayed installs and blocklist:
// an unpacked extension always installs immediately here.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_REGISTRAR_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_REGISTRAR_DELEGATE_H_

#include "base/memory/raw_ptr.h"
#include "extensions/browser/extension_registrar.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

class OrbitExtensionRegistrarDelegate : public extensions::ExtensionRegistrar::Delegate {
 public:
  explicit OrbitExtensionRegistrarDelegate(content::BrowserContext* browser_context);
  OrbitExtensionRegistrarDelegate(const OrbitExtensionRegistrarDelegate&) = delete;
  OrbitExtensionRegistrarDelegate& operator=(const OrbitExtensionRegistrarDelegate&) = delete;
  ~OrbitExtensionRegistrarDelegate() override;

  // Must be called once, with the ExtensionRegistrar this delegate was
  // passed to via Init() -- OnExtensionInstalled() routes back into it.
  void SetExtensionRegistrar(extensions::ExtensionRegistrar* registrar);

  // extensions::ExtensionRegistrar::Delegate:
  void PreAddExtension(const extensions::Extension* extension,
                       const extensions::Extension* old_extension) override;
  void OnAddNewOrUpdatedExtension(const extensions::Extension* extension) override;
  void PostActivateExtension(
      scoped_refptr<const extensions::Extension> extension) override;
  void PostDeactivateExtension(
      scoped_refptr<const extensions::Extension> extension) override;
  void PreUninstallExtension(
      scoped_refptr<const extensions::Extension> extension) override;
  void PostUninstallExtension(scoped_refptr<const extensions::Extension> extension,
                              base::OnceClosure done_callback) override;
  void LoadExtensionForReload(const extensions::ExtensionId& extension_id,
                              const base::FilePath& path) override;
  void LoadExtensionForReloadWithQuietFailure(
      const extensions::ExtensionId& extension_id,
      const base::FilePath& path) override;
  void ShowExtensionDisabledError(const extensions::Extension* extension,
                                  bool is_remote_install) override;
  bool CanEnableExtension(const extensions::Extension* extension) override;
  bool CanDisableExtension(const extensions::Extension* extension) override;
  void GrantActivePermissions(const extensions::Extension* extension) override;
  void UpdateExternalExtensionAlert() override;
  void OnExtensionInstalled(const extensions::Extension* extension,
                            const syncer::StringOrdinal& page_ordinal,
                            int install_flags,
                            base::DictValue ruleset_install_prefs) override;

 private:
  raw_ptr<content::BrowserContext> browser_context_;
  raw_ptr<extensions::ExtensionRegistrar> extension_registrar_ = nullptr;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_EXTENSION_REGISTRAR_DELEGATE_H_
