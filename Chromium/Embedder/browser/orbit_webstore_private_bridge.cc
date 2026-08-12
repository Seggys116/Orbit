// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_webstore_private_bridge.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/json/json_writer.h"
#include "content/public/browser/web_contents.h"
#include "orbit/browser/orbit_web_contents_host.h"

namespace orbit {

namespace {

constexpr char kNoHostErrorJSON[] =
    R"({"ok":false,"error":{"message":"No OrbitWebContentsHost for this tab."}})";

}  // namespace

void RequestFromNativeWebstorePrivateBridge(
    content::WebContents* web_contents,
    const std::string& method,
    base::ListValue args,
    base::OnceCallback<void(std::string result_json)> callback) {
  OrbitWebContentsHost* host =
      web_contents ? OrbitWebContentsHost::FromWebContents(web_contents)
                   : nullptr;
  if (!host) {
    std::move(callback).Run(kNoHostErrorJSON);
    return;
  }
  host->RequestFromNativeExtensionBridge(method, std::move(args),
                                         std::move(callback));
}

}  // namespace orbit
