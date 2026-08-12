// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// C++-linkage counterpart to orbit_bridge_api.h's C ABI. Kept separate so
// nothing here needs to survive a dlsym lookup.

#ifndef ORBIT_EMBEDDER_BRIDGE_ORBIT_BRIDGE_INTERNAL_H_
#define ORBIT_EMBEDDER_BRIDGE_ORBIT_BRIDGE_INTERNAL_H_

#include <cstdint>
#include <string>
#include <vector>

#include "base/functional/callback_forward.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

class OrbitBrowserContext;
class OrbitWebContentsHost;

// Called once, from PreMainMessageLoopRun, after browser_context is
// constructed. Fires the Swift-registered ready callback, if any is already
// registered (see OrbitSetBrowserReadyCallback).
void NotifyOrbitBrowserReady(OrbitBrowserContext* browser_context);

// Called once, from WillRunMainMessageLoop, so OrbitRequestBrowserQuit has
// something to run.
void SetOrbitBrowserQuitClosure(base::OnceClosure quit_closure);

// Called from PostMainMessageLoopRun so a later OrbitWebContentsCreate fails
// honestly instead of dereferencing a dangling browser_context.
void ClearOrbitBrowserState();

// What OrbitContentBlockingURLLoaderFactory should do with one request.
// `mime_type`/`body` are meaningful only for kSubstitute.
struct ContentBlockingRequestDecision {
  enum class Kind { kAllow, kBlock, kSubstitute };

  Kind kind = Kind::kAllow;
  std::string mime_type;
  std::vector<uint8_t> body;
};

// Always kAllow if Swift has never called
// OrbitSetContentBlockingDecisionCallback. Safe to call from any sequence.
ContentBlockingRequestDecision DecideContentBlocking(
    const std::string& request_url,
    const std::string& document_url,
    int resource_type);

// True if a real, enabled ContentBlocker is currently pushed -- see
// OrbitSetContentBlockingActive's comment in orbit_bridge_api.h. UI-thread
// only, matching WillCreateURLLoaderFactory, its one caller.
bool IsContentBlockingActive();

// The single OrbitBrowserContext, upcast to content::BrowserContext --
// nullptr before NotifyOrbitBrowserReady or after ClearOrbitBrowserState.
content::BrowserContext* GetOrbitBrowserContext();

// Asks Swift to adopt `host` (already built for window.open()-style
// navigation from an extension) as a real Orbit tab. `host` must already
// exist via OrbitWebContentsHost's adopting constructor. Caller owns
// destroying it if this returns false, including when no delegate is
// registered.
bool RequestExtensionTab(OrbitWebContentsHost* host,
                         const std::string& url,
                         const std::string& extension_id,
                         int disposition,
                         bool user_gesture);

// Asks Swift to host one page-initiated new-content request. `host` is null
// for the "nothing built yet" route; otherwise the caller owns destroying
// it if this returns false. False (nothing dispatched) if no delegate is
// registered -- treat as a refusal.
bool RequestNewContent(OrbitWebContentsHost* source,
                       OrbitWebContentsHost* host,
                       const std::string& url,
                       int disposition,
                       bool user_gesture);

// One primary-main-frame certificate error, already reduced to the strings
// and numbers OrbitCertificateErrorCallback carries -- see orbit_bridge_api.h
// for each field's meaning.
struct CertificateErrorReport {
  std::string request_url;
  std::string host;
  int cert_error = 0;
  std::string error_name;
  std::string issuer;
  std::string subject;
  double valid_from = 0;
  double valid_until = 0;
  bool overridable = false;
};

// Hands one certificate error to Swift. False, with nothing dispatched, when
// Swift has never called OrbitSetCertificateErrorCallback -- which the caller
// must treat as a refusal, never as consent.
bool DispatchCertificateError(OrbitWebContentsHost* host,
                              uint64_t request_id,
                              const CertificateErrorReport& report);

// chrome.management's enable/disable, routed to Orbit's ExtensionStore so the
// on-disk record and the running engine stay in step. False if Swift has
// never called OrbitSetManagementDelegate.
bool ManagementSetExtensionEnabled(const std::string& extension_id,
                                   bool enabled);

// Asks Swift to put the uninstall to the user; `callback` runs with their
// answer. Returns false without running `callback` when there is no
// delegate -- treat as "refused", never as consent.
bool ManagementRequestUninstallConsent(const std::string& extension_id,
                                       base::OnceCallback<void(bool)> callback);

// Performs the removal itself, only after the consent above was granted.
bool ManagementUninstallExtension(const std::string& extension_id);

// Asks Swift to put one chrome.permissions.request to the user; `callback`
// runs with their answer. Returns false without running `callback` when
// there is no delegate -- treat as "refused", never as consent.
bool RequestPermissionsConsent(const std::string& request_json,
                               base::OnceCallback<void(bool)> callback);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BRIDGE_ORBIT_BRIDGE_INTERNAL_H_
