// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_download_manager_delegate.h"

#include <memory>
#include <utility>

#include "base/base_paths.h"
#include "base/files/file_path.h"
#include "base/files/file_util.h"
#include "base/functional/bind.h"
#include "base/path_service.h"
#include "components/download/public/common/download_item.h"
#include "components/download/public/common/download_target_info.h"
#include "content/public/browser/download_item_utils.h"
#include "net/base/filename_util.h"
#include "orbit/browser/orbit_web_contents_host.h"

namespace orbit {

namespace {

// Fallback when no OrbitWebContentsHost is left to ask: ~/Downloads,
// unique-ified so an existing same-named file is never overwritten.
base::FilePath DefaultDownloadPath(const base::FilePath& suggested_name) {
  base::FilePath home;
  if (!base::PathService::Get(base::DIR_HOME, &home)) {
    return base::FilePath();
  }
  const base::FilePath directory = home.Append("Downloads");
  if (!base::DirectoryExists(directory) && !base::CreateDirectory(directory)) {
    return base::FilePath();
  }
  return base::GetUniquePath(directory.Append(suggested_name));
}

base::FilePath SuggestedFileName(const download::DownloadItem& item) {
  return net::GenerateFileName(item.GetURL(), item.GetContentDisposition(),
                               /*referrer_charset=*/std::string(),
                               item.GetSuggestedFilename(), item.GetMimeType(),
                               /*default_name=*/"download");
}

int DownloadStateForSwift(const download::DownloadItem& item) {
  switch (item.GetState()) {
    case download::DownloadItem::IN_PROGRESS:
      return item.IsPaused() ? 2 : 1;
    case download::DownloadItem::COMPLETE:
      return 3;
    case download::DownloadItem::CANCELLED:
      return 4;
    case download::DownloadItem::INTERRUPTED:
      return 5;
    case download::DownloadItem::MAX_DOWNLOAD_STATE:
      break;
  }
  return 0;
}

// The tab that started this download, if still open; falls back to any open
// tab so it still reaches Swift once the originating tab has closed.
OrbitWebContentsHost* HostForDownload(const download::DownloadItem& item) {
  content::WebContents* web_contents =
      content::DownloadItemUtils::GetOriginalWebContents(&item);
  OrbitWebContentsHost* host =
      web_contents ? OrbitWebContentsHost::FromWebContents(web_contents) : nullptr;
  return host ? host : OrbitWebContentsHost::AnyLiveHost();
}

// The C completion callback handed to Swift; `opaque` is the OnceCallback
// this delegate allocated for exactly one call, deleted here when it fires.
void HandleDownloadTargetFromSwift(void* opaque, const char* target_path) {
  std::unique_ptr<base::OnceCallback<void(const std::string&)>> callback(
      static_cast<base::OnceCallback<void(const std::string&)>*>(opaque));
  std::move(*callback).Run(target_path ? std::string(target_path) : std::string());
}

}  // namespace

OrbitDownloadManagerDelegate::OrbitDownloadManagerDelegate() = default;

OrbitDownloadManagerDelegate::~OrbitDownloadManagerDelegate() = default;

void OrbitDownloadManagerDelegate::SetDownloadManager(content::DownloadManager* manager) {
  download_manager_ = manager;
  download_manager_->AddObserver(this);
}

void OrbitDownloadManagerDelegate::Shutdown() {
  weak_ptr_factory_.InvalidateWeakPtrs();
  if (download_manager_) {
    download_manager_->RemoveObserver(this);
  }
  download_manager_ = nullptr;
}

void OrbitDownloadManagerDelegate::GetNextId(content::DownloadIdCallback callback) {
  static uint32_t next_id = download::DownloadItem::kInvalidId + 1;
  std::move(callback).Run(next_id++);
}

bool OrbitDownloadManagerDelegate::DetermineDownloadTarget(
    download::DownloadItem* item,
    download::DownloadTargetCallback* callback) {
  if (!item->GetForcedFilePath().empty()) {
    download::DownloadTargetInfo target_info;
    target_info.target_path = item->GetForcedFilePath();
    target_info.intermediate_path = item->GetForcedFilePath();
    std::move(*callback).Run(std::move(target_info));
    return true;
  }

  auto reply = base::BindOnce(&OrbitDownloadManagerDelegate::OnTargetPathChosen,
                              weak_ptr_factory_.GetWeakPtr(), std::move(*callback));

  OrbitWebContentsHost* host = HostForDownload(*item);
  const base::FilePath suggested_name = SuggestedFileName(*item);

  if (!host) {
    // No tab left to ask at all -- ~/Downloads, unique-ified, rather than
    // silently dropping the download.
    const base::FilePath fallback = DefaultDownloadPath(suggested_name);
    std::move(reply).Run(fallback.AsUTF8Unsafe());
    return true;
  }

  // Owns itself: HandleDownloadTargetFromSwift deletes it the one time
  // Swift calls back, guaranteed to happen exactly once.
  auto* callback_holder = new base::OnceCallback<void(const std::string&)>(std::move(reply));
  host->RequestDownloadTarget(item->GetGuid(), suggested_name.AsUTF8Unsafe(),
                              item->GetMimeType(), item->GetTotalBytes(),
                              item->GetURL().spec(), &HandleDownloadTargetFromSwift,
                              callback_holder);
  return true;
}

void OrbitDownloadManagerDelegate::OnTargetPathChosen(
    download::DownloadTargetCallback callback,
    const std::string& target_path) {
  download::DownloadTargetInfo target_info;
  if (target_path.empty()) {
    // Cancel -- content::DownloadManagerDelegate::DetermineDownloadTarget's
    // own contract for an empty target_path.
    std::move(callback).Run(std::move(target_info));
    return;
  }
  const base::FilePath path = base::FilePath::FromUTF8Unsafe(target_path);
  target_info.target_path = path;
  target_info.intermediate_path = path.AddExtension(FILE_PATH_LITERAL(".crdownload"));
  target_info.target_disposition = download::DownloadItem::TARGET_DISPOSITION_OVERWRITE;
  std::move(callback).Run(std::move(target_info));
}

bool OrbitDownloadManagerDelegate::ShouldOpenDownload(download::DownloadItem*,
                                                      content::DownloadOpenDelayedCallback) {
  // True = declines to add auto-open behaviour; Orbit's UI offers an
  // explicit Open action instead.
  return true;
}

void OrbitDownloadManagerDelegate::OnDownloadCreated(content::DownloadManager*,
                                                     download::DownloadItem* item) {
  item->AddObserver(this);
}

void OrbitDownloadManagerDelegate::ManagerGoingDown(content::DownloadManager*) {
  download_manager_ = nullptr;
}

void OrbitDownloadManagerDelegate::OnDownloadUpdated(download::DownloadItem* item) {
  if (OrbitWebContentsHost* host = HostForDownload(*item)) {
    host->ReportDownloadProgress(item->GetGuid(), item->GetReceivedBytes(),
                                 item->GetTotalBytes(), DownloadStateForSwift(*item));
  }
}

void OrbitDownloadManagerDelegate::OnDownloadDestroyed(download::DownloadItem* item) {
  item->RemoveObserver(this);
}

}  // namespace orbit
