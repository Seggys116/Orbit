// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_webstore_private_api.h"

#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/values.h"
#include "base/version_info/version_info.h"
#include "orbit/browser/orbit_webstore_private_bridge.h"

namespace orbit {

namespace webstore_private = api::webstore_private;

namespace {

// Splits the {"ok":bool,...} envelope from RequestFromNativeWebstorePrivateBridge
// (matches WebStorePrivateBridge.encode(_:)); on ok:true, `*out_result` is the "result"
// value, left as Value() (a JSON null) for a result-less success (e.g. completeInstall's
// NSNull()); on ok:false, `*out_error` is set to "error.message".
bool ParseBridgeEnvelope(const std::string& result_json,
                         base::Value* out_result,
                         std::string* out_error) {
  std::optional<base::Value> parsed =
      base::JSONReader::Read(result_json, base::JSON_PARSE_RFC);
  const base::DictValue* dict = parsed ? parsed->GetIfDict() : nullptr;
  if (!dict) {
    *out_error = "Malformed response from the native install bridge.";
    return false;
  }
  if (dict->FindBool("ok").value_or(false)) {
    if (const base::Value* result = dict->Find("result")) {
      *out_result = result->Clone();
    }
    return true;
  }
  const std::string* message = dict->FindStringByDottedPath("error.message");
  *out_error = message ? *message : "Unknown error";
  return false;
}

}  // namespace

// MARK: - beginInstallWithManifest3
// Feasibility-only (id validity, not-installed, manifest parses); never shows UI.
// The real consent prompt is in completeInstall, built from the verified manifest.

ExtensionFunction::ResponseAction
WebstorePrivateBeginInstallWithManifest3Function::Run() {
  std::optional<webstore_private::BeginInstallWithManifest3::Params> params =
      webstore_private::BeginInstallWithManifest3::Params::Create(args());
  if (!params) {
    return RespondNow(ArgumentList(
        webstore_private::BeginInstallWithManifest3::Results::Create(
            webstore_private::Result::kManifestError)));
  }

  base::DictValue details;
  details.Set("id", params->details.id);
  details.Set("manifest", params->details.manifest);

  base::ListValue bridge_args;
  bridge_args.Append(std::move(details));

  RequestFromNativeWebstorePrivateBridge(
      GetSenderWebContents(), "beginInstallWithManifest3",
      std::move(bridge_args),
      base::BindOnce(
          &WebstorePrivateBeginInstallWithManifest3Function::OnBridgeResponse,
          this));
  return RespondLater();
}

void WebstorePrivateBeginInstallWithManifest3Function::OnBridgeResponse(
    std::string result_json) {
  base::Value result_value;
  std::string error;
  webstore_private::Result result = webstore_private::Result::kUnknownError;
  if (ParseBridgeEnvelope(result_json, &result_value, &error)) {
    if (const std::string* token = result_value.GetIfString()) {
      result = webstore_private::ParseResult(*token);
    } else {
      result = webstore_private::Result::kEmptyString;
    }
  }
  Respond(ArgumentList(
      webstore_private::BeginInstallWithManifest3::Results::Create(result)));
}

// MARK: - completeInstall
// The only consent prompt in this pipeline: Swift downloads and CRX3-verifies
// the real CRX first, so the prompt always shows the true manifest, never what the page claimed.

ExtensionFunction::ResponseAction
WebstorePrivateCompleteInstallFunction::Run() {
  std::optional<webstore_private::CompleteInstall::Params> params =
      webstore_private::CompleteInstall::Params::Create(args());
  if (!params) {
    return RespondNow(Error("completeInstall requires an extension id."));
  }

  base::ListValue bridge_args;
  bridge_args.Append(params->expected_id);

  RequestFromNativeWebstorePrivateBridge(
      GetSenderWebContents(), "completeInstall", std::move(bridge_args),
      base::BindOnce(&WebstorePrivateCompleteInstallFunction::OnBridgeResponse,
                     this));
  return RespondLater();
}

void WebstorePrivateCompleteInstallFunction::OnBridgeResponse(
    std::string result_json) {
  base::Value result_value;
  std::string error;
  if (!ParseBridgeEnvelope(result_json, &result_value, &error)) {
    // A raw Result token (e.g. "user_cancelled", "already_installed"), matching
    // webstorePrivate.completeInstall's real contract: errors surface via chrome.runtime.lastError.message alone.
    Respond(Error(error));
    return;
  }
  Respond(ArgumentList(webstore_private::CompleteInstall::Results::Create()));
}

// MARK: - getExtensionStatus

ExtensionFunction::ResponseAction
WebstorePrivateGetExtensionStatusFunction::Run() {
  std::optional<webstore_private::GetExtensionStatus::Params> params =
      webstore_private::GetExtensionStatus::Params::Create(args());
  if (!params) {
    return RespondNow(Error("getExtensionStatus requires an extension id."));
  }

  base::ListValue bridge_args;
  bridge_args.Append(params->id);
  bridge_args.Append(params->manifest ? base::Value(*params->manifest)
                                      : base::Value());

  RequestFromNativeWebstorePrivateBridge(
      GetSenderWebContents(), "getExtensionStatus", std::move(bridge_args),
      base::BindOnce(
          &WebstorePrivateGetExtensionStatusFunction::OnBridgeResponse, this));
  return RespondLater();
}

void WebstorePrivateGetExtensionStatusFunction::OnBridgeResponse(
    std::string result_json) {
  base::Value result_value;
  std::string error;
  webstore_private::ExtensionInstallStatus status =
      webstore_private::ExtensionInstallStatus::kInstallable;
  if (ParseBridgeEnvelope(result_json, &result_value, &error)) {
    if (const std::string* token = result_value.GetIfString()) {
      status = webstore_private::ParseExtensionInstallStatus(*token);
    }
  }
  Respond(ArgumentList(
      webstore_private::GetExtensionStatus::Results::Create(status)));
}

// MARK: - Everything else: pure, local, no Swift round trip -- matches the
// constants WebStorePrivateBridge.swift already answers with.

ExtensionFunction::ResponseAction WebstorePrivateGetStoreLoginFunction::Run() {
  return RespondNow(ArgumentList(
      webstore_private::GetStoreLogin::Results::Create(std::string())));
}

ExtensionFunction::ResponseAction WebstorePrivateSetStoreLoginFunction::Run() {
  // Accepted, never persisted -- matches getStoreLogin always answering "".
  return RespondNow(NoArguments());
}

ExtensionFunction::ResponseAction
WebstorePrivateGetWebGLStatusFunction::Run() {
  return RespondNow(
      ArgumentList(webstore_private::GetWebGLStatus::Results::Create(
          webstore_private::WebGlStatus::kWebglAllowed)));
}

ExtensionFunction::ResponseAction
WebstorePrivateIsPendingCustodianApprovalFunction::Run() {
  return RespondNow(ArgumentList(
      webstore_private::IsPendingCustodianApproval::Results::Create(false)));
}

ExtensionFunction::ResponseAction
WebstorePrivateGetReferrerChainFunction::Run() {
  // Constant used by NeverDecaf/chromium-web-store, proven in production.
  return RespondNow(ArgumentList(
      webstore_private::GetReferrerChain::Results::Create("EgIIAA==")));
}

ExtensionFunction::ResponseAction
WebstorePrivateGetFullChromeVersionFunction::Run() {
  webstore_private::GetFullChromeVersion::Results::Info info;
  info.version_number = std::string(version_info::GetVersionNumber());
  return RespondNow(ArgumentList(
      webstore_private::GetFullChromeVersion::Results::Create(info)));
}

}  // namespace orbit
