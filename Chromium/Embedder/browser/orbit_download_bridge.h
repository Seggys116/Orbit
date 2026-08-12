// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// download::DownloadItem lookup-by-GUID; keyed by the download's own id,
// not a tab handle, since a download outlives the WebContents that started it.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_BRIDGE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_BRIDGE_H_

#include <string>

namespace content {
class BrowserContext;
}  // namespace content

namespace orbit {

// No-op if browser_context is null or no download with this GUID is tracked.
void CancelDownload(content::BrowserContext* browser_context, const std::string& guid);
void PauseDownload(content::BrowserContext* browser_context, const std::string& guid);
void ResumeDownload(content::BrowserContext* browser_context, const std::string& guid);

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_BRIDGE_H_
