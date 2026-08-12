// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_HTTP_AUTH_LOGIN_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_HTTP_AUTH_LOGIN_DELEGATE_H_

#include <optional>

#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "content/public/browser/global_request_id.h"
#include "content/public/browser/login_delegate.h"
#include "net/base/auth.h"
#include "net/http/http_response_headers.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

// Offers 401/407 challenges to chrome.webRequest.onAuthRequired; a challenge no
// extension claims is cancelled, matching content::'s pre-existing no-UI behaviour.
class OrbitHttpAuthLoginDelegate : public content::LoginDelegate {
 public:
  OrbitHttpAuthLoginDelegate(
      content::BrowserContext* browser_context,
      const net::AuthChallengeInfo& auth_info,
      scoped_refptr<net::HttpResponseHeaders> response_headers,
      const content::GlobalRequestID& request_id,
      bool is_request_for_navigation,
      LoginAuthRequiredCallback auth_required_callback);

  OrbitHttpAuthLoginDelegate(const OrbitHttpAuthLoginDelegate&) = delete;
  OrbitHttpAuthLoginDelegate& operator=(const OrbitHttpAuthLoginDelegate&) =
      delete;

  ~OrbitHttpAuthLoginDelegate() override;

 private:
  void OnExtensionResponse(
      const std::optional<net::AuthCredentials>& credentials,
      bool should_cancel);
  void Cancel();

  LoginAuthRequiredCallback callback_;
  base::WeakPtrFactory<OrbitHttpAuthLoginDelegate> weak_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_HTTP_AUTH_LOGIN_DELEGATE_H_
