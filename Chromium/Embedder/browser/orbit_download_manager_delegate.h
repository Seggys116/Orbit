// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Target-path selection, progress relay and lifecycle for every DownloadItem;
// content:: detects the download and routes it here. Modelled on
// shell_download_manager_delegate.h.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_MANAGER_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_MANAGER_DELEGATE_H_

#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "content/public/browser/download_manager.h"
#include "content/public/browser/download_manager_delegate.h"
#include "components/download/public/common/download_item.h"

namespace orbit {

class OrbitDownloadManagerDelegate : public content::DownloadManagerDelegate,
                                     public content::DownloadManager::Observer,
                                     public download::DownloadItem::Observer {
 public:
  OrbitDownloadManagerDelegate();
  OrbitDownloadManagerDelegate(const OrbitDownloadManagerDelegate&) = delete;
  OrbitDownloadManagerDelegate& operator=(const OrbitDownloadManagerDelegate&) = delete;
  ~OrbitDownloadManagerDelegate() override;

  void SetDownloadManager(content::DownloadManager* manager);

  // content::DownloadManagerDelegate:
  void Shutdown() override;
  void GetNextId(content::DownloadIdCallback callback) override;
  bool DetermineDownloadTarget(download::DownloadItem* item,
                               download::DownloadTargetCallback* callback) override;
  bool ShouldOpenDownload(download::DownloadItem* item,
                          content::DownloadOpenDelayedCallback callback) override;

  // content::DownloadManager::Observer:
  void OnDownloadCreated(content::DownloadManager* manager,
                         download::DownloadItem* item) override;
  void ManagerGoingDown(content::DownloadManager* manager) override;

  // download::DownloadItem::Observer:
  void OnDownloadUpdated(download::DownloadItem* item) override;
  void OnDownloadDestroyed(download::DownloadItem* item) override;

 private:
  void OnTargetPathChosen(download::DownloadTargetCallback callback,
                          const std::string& target_path);

  raw_ptr<content::DownloadManager> download_manager_ = nullptr;
  base::WeakPtrFactory<OrbitDownloadManagerDelegate> weak_ptr_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_DOWNLOAD_MANAGER_DELEGATE_H_
