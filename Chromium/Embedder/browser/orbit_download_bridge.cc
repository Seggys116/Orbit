// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_download_bridge.h"

#include "content/public/browser/browser_context.h"
#include "content/public/browser/download_manager.h"
#include "components/download/public/common/download_item.h"

namespace orbit {

namespace {

download::DownloadItem* FindDownload(content::BrowserContext* browser_context,
                                     const std::string& guid) {
  if (!browser_context || guid.empty()) {
    return nullptr;
  }
  return browser_context->GetDownloadManager()->GetDownloadByGuid(guid);
}

}  // namespace

void CancelDownload(content::BrowserContext* browser_context, const std::string& guid) {
  if (download::DownloadItem* item = FindDownload(browser_context, guid)) {
    item->Cancel(/*user_cancel=*/true);
  }
}

void PauseDownload(content::BrowserContext* browser_context, const std::string& guid) {
  if (download::DownloadItem* item = FindDownload(browser_context, guid)) {
    item->Pause();
  }
}

void ResumeDownload(content::BrowserContext* browser_context, const std::string& guid) {
  if (download::DownloadItem* item = FindDownload(browser_context, guid)) {
    if (item->CanResume()) {
      item->Resume(/*user_resume=*/true);
    }
  }
}

}  // namespace orbit
