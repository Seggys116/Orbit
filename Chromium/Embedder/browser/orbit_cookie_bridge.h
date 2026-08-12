// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// JSON in/out wrapper over network::mojom::CookieManager so orbit_bridge_api.cc
// never sees net:: or network::mojom:: types.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_COOKIE_BRIDGE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_COOKIE_BRIDGE_H_

#include <string>

#include "base/functional/callback_forward.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

// JSON array of {"name","value","domain","path","secure","httpOnly",
// "sameSite","expiresAt","createdAt","lastAccessedAt"}; see OrbitGetCookies.
// Always calls `callback` exactly once; "[]" on null context or failure.
void GetCookiesJSON(content::BrowserContext* browser_context,
                    const std::string& url,
                    base::OnceCallback<void(std::string)> callback);

// See OrbitDeleteCookies. Always calls `callback` exactly once.
void DeleteCookiesForURL(content::BrowserContext* browser_context,
                         const std::string& url,
                         base::OnceClosure callback);

// `cookies_json` is in GetCookiesJSON's shape; see OrbitSetCookies.
// Always calls `callback` exactly once, with the count actually accepted.
void SetCookiesJSON(content::BrowserContext* browser_context,
                    const std::string& cookies_json,
                    base::OnceCallback<void(int)> callback);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_COOKIE_BRIDGE_H_
