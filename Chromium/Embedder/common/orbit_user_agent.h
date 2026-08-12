// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// The identity Orbit presents to websites, overriding content::
// ContentBrowserClient's empty defaults. Presents as Chrome of the embedded
// Chromium's major version, matching Scripts/chromium's ChromiumBuild.userAgent
// byte-for-byte, and declares Orbit in the client-hints brand list.

#ifndef ORBIT_EMBEDDER_COMMON_ORBIT_USER_AGENT_H_
#define ORBIT_EMBEDDER_COMMON_ORBIT_USER_AGENT_H_

#include <string>

#include "third_party/blink/public/common/user_agent/user_agent_metadata.h"

namespace orbit {

// "Chrome/<chromium major>.0.0.0".
std::string GetProduct();

// The full User-Agent header value, honouring --user-agent when given.
std::string GetUserAgent();

// Brand lists carrying Chromium, Google Chrome, Orbit and Chromium's own
// GREASE entry; every other field is Chromium's real value for this machine.
blink::UserAgentMetadata GetUserAgentMetadata();

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_COMMON_ORBIT_USER_AGENT_H_
