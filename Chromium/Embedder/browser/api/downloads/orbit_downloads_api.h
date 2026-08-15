// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_API_DOWNLOADS_ORBIT_DOWNLOADS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_DOWNLOADS_ORBIT_DOWNLOADS_API_H_

#include "components/download/public/common/download_interrupt_reasons.h"
#include "extensions/browser/extension_function.h"

namespace download {
class DownloadItem;
}  // namespace download

namespace orbit {

class DownloadsDownloadFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.download", DOWNLOADS_DOWNLOAD)

 protected:
  ~DownloadsDownloadFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnStarted(download::DownloadItem* item,
                 download::DownloadInterruptReason interrupt_reason);
  void OnIdResolved(int id);
};

class DownloadsSearchFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.search", DOWNLOADS_SEARCH)

 protected:
  ~DownloadsSearchFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsPauseFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.pause", DOWNLOADS_PAUSE)

 protected:
  ~DownloadsPauseFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsResumeFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.resume", DOWNLOADS_RESUME)

 protected:
  ~DownloadsResumeFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsCancelFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.cancel", DOWNLOADS_CANCEL)

 protected:
  ~DownloadsCancelFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsOpenFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.open", DOWNLOADS_OPEN)

 protected:
  ~DownloadsOpenFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsShowFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.show", DOWNLOADS_SHOW)

 protected:
  ~DownloadsShowFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsShowDefaultFolderFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.showDefaultFolder",
                             DOWNLOADS_SHOWDEFAULTFOLDER)

 protected:
  ~DownloadsShowDefaultFolderFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsEraseFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.erase", DOWNLOADS_ERASE)

 protected:
  ~DownloadsEraseFunction() override = default;
  ResponseAction Run() override;
};

class DownloadsRemoveFileFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("downloads.removeFile", DOWNLOADS_REMOVEFILE)

 protected:
  ~DownloadsRemoveFileFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_DOWNLOADS_ORBIT_DOWNLOADS_API_H_
