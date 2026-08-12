// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_http_auth_login_delegate.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/location.h"
#include "base/task/sequenced_task_runner.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "extensions/browser/api/web_request/web_request_api.h"
#include "extensions/browser/browser_context_keyed_api_factory.h"

namespace orbit {

OrbitHttpAuthLoginDelegate::OrbitHttpAuthLoginDelegate(
    content::BrowserContext* browser_context,
    const net::AuthChallengeInfo& auth_info,
    scoped_refptr<net::HttpResponseHeaders> response_headers,
    const content::GlobalRequestID& request_id,
    bool is_request_for_navigation,
    LoginAuthRequiredCallback auth_required_callback)
    : callback_(std::move(auth_required_callback)) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);

  auto* web_request_api =
      extensions::BrowserContextKeyedAPIFactory<extensions::WebRequestAPI>::Get(
          browser_context);
  if (web_request_api &&
      web_request_api->MaybeProxyAuthRequest(
          browser_context, auth_info, std::move(response_headers), request_id,
          is_request_for_navigation,
          base::BindOnce(&OrbitHttpAuthLoginDelegate::OnExtensionResponse,
                         weak_factory_.GetWeakPtr()),
          /*web_view_guest=*/nullptr)) {
    return;
  }

  // Never reentrantly: content:: has not been handed this delegate yet.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(&OrbitHttpAuthLoginDelegate::Cancel,
                                weak_factory_.GetWeakPtr()));
}

OrbitHttpAuthLoginDelegate::~OrbitHttpAuthLoginDelegate() = default;

void OrbitHttpAuthLoginDelegate::OnExtensionResponse(
    const std::optional<net::AuthCredentials>& credentials,
    bool should_cancel) {
  if (!callback_) {
    return;
  }
  if (credentials) {
    std::move(callback_).Run(credentials);
    return;
  }
  // `should_cancel` false means "no extension answered, fall back to the
  // browser's own prompt". Orbit has no prompt, so both arms cancel.
  std::move(callback_).Run(std::nullopt);
}

void OrbitHttpAuthLoginDelegate::Cancel() {
  if (!callback_) {
    return;
  }
  std::move(callback_).Run(std::nullopt);
}

}  // namespace orbit
