// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.webstorePrivate, backed by Orbit's own verified install pipeline via
// orbit_webstore_private_bridge.h, not chrome's WebstoreInstaller stack. Registered by hand; uses generated Params/Results (unlike tabs/windows).

#ifndef ORBIT_EMBEDDER_BROWSER_API_WEBSTORE_PRIVATE_ORBIT_WEBSTORE_PRIVATE_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_WEBSTORE_PRIVATE_ORBIT_WEBSTORE_PRIVATE_API_H_

#include <string>

#include "extensions/browser/extension_function.h"
#include "orbit/common/api/webstore_private.h"

namespace orbit {

class WebstorePrivateBeginInstallWithManifest3Function
    : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.beginInstallWithManifest3", UNKNOWN)

 protected:
  ~WebstorePrivateBeginInstallWithManifest3Function() override = default;
  ResponseAction Run() override;

 private:
  void OnBridgeResponse(std::string result_json);
};

class WebstorePrivateCompleteInstallFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.completeInstall", UNKNOWN)

 protected:
  ~WebstorePrivateCompleteInstallFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnBridgeResponse(std::string result_json);
};

class WebstorePrivateGetExtensionStatusFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.getExtensionStatus", UNKNOWN)

 protected:
  ~WebstorePrivateGetExtensionStatusFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnBridgeResponse(std::string result_json);
};

class WebstorePrivateGetStoreLoginFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.getStoreLogin", UNKNOWN)

 protected:
  ~WebstorePrivateGetStoreLoginFunction() override = default;
  ResponseAction Run() override;
};

class WebstorePrivateSetStoreLoginFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.setStoreLogin", UNKNOWN)

 protected:
  ~WebstorePrivateSetStoreLoginFunction() override = default;
  ResponseAction Run() override;
};

class WebstorePrivateGetWebGLStatusFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.getWebGLStatus", UNKNOWN)

 protected:
  ~WebstorePrivateGetWebGLStatusFunction() override = default;
  ResponseAction Run() override;
};

class WebstorePrivateIsPendingCustodianApprovalFunction
    : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.isPendingCustodianApproval", UNKNOWN)

 protected:
  ~WebstorePrivateIsPendingCustodianApprovalFunction() override = default;
  ResponseAction Run() override;
};

class WebstorePrivateGetReferrerChainFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.getReferrerChain", UNKNOWN)

 protected:
  ~WebstorePrivateGetReferrerChainFunction() override = default;
  ResponseAction Run() override;
};

class WebstorePrivateGetFullChromeVersionFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("webstorePrivate.getFullChromeVersion", UNKNOWN)

 protected:
  ~WebstorePrivateGetFullChromeVersionFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_WEBSTORE_PRIVATE_ORBIT_WEBSTORE_PRIVATE_API_H_
