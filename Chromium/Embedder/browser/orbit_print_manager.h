// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// PrintManagerHost implementation exposing only PrintToPdf(); content:: has no printing
// API of its own. Modelled on headless::HeadlessPrintManager, which solves this the same way.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_PRINT_MANAGER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_PRINT_MANAGER_H_

#include <string>

#include "build/build_config.h"
#include "components/printing/browser/print_manager.h"
#include "components/printing/browser/print_to_pdf/pdf_print_job.h"
#include "components/printing/common/print.mojom.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents_observer.h"
#include "content/public/browser/web_contents_user_data.h"
#include "printing/buildflags/buildflags.h"

namespace orbit {

class OrbitPrintManager : public printing::PrintManager,
                          public content::WebContentsUserData<OrbitPrintManager> {
 public:
  ~OrbitPrintManager() override;

  OrbitPrintManager(const OrbitPrintManager&) = delete;
  OrbitPrintManager& operator=(const OrbitPrintManager&) = delete;

  static void BindPrintManagerHost(
      mojo::PendingAssociatedReceiver<printing::mojom::PrintManagerHost> receiver,
      content::RenderFrameHost* rfh);

  void PrintToPdf(content::RenderFrameHost* rfh,
                  const std::string& page_ranges,
                  printing::mojom::PrintPagesParamsPtr print_page_params,
                  print_to_pdf::PdfPrintJob::PrintToPdfCallback callback);

 private:
  friend class content::WebContentsUserData<OrbitPrintManager>;

  explicit OrbitPrintManager(content::WebContents* web_contents);

  // printing::mojom::PrintManagerHost -- scripted (window.print()) and
  // print-preview requests are refused outright: Orbit has no print dialog or
  // preview UI, only the direct print-to-PDF path PrintToPdf above serves.
  void GetDefaultPrintSettings(GetDefaultPrintSettingsCallback callback) override;
  void ScriptedPrint(printing::mojom::ScriptedPrintParamsPtr params,
                     ScriptedPrintCallback callback) override;
#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
  void GetPrintPreviewParams(GetPrintPreviewParamsCallback callback) override;
  void SetupScriptedPrintPreview(SetupScriptedPrintPreviewCallback callback) override;
  void ShowScriptedPrintPreview() override;
  void RequestPrintPreview(printing::mojom::RequestPrintPreviewParamsPtr params) override;
  void CheckForCancel(const base::UnguessableToken& preview_ui_id,
                      int32_t request_id,
                      CheckForCancelCallback callback) override;
  void SetAccessibilityTree(int32_t cookie,
                            const ui::AXTreeUpdate& accessibility_tree) override;
#endif
#if BUILDFLAG(IS_ANDROID)
  void SetupScriptedPrintAndroid(SetupScriptedPrintAndroidCallback callback) override;
  void PdfWritingDone(int page_count) override;
#endif

  WEB_CONTENTS_USER_DATA_KEY_DECL();
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_PRINT_MANAGER_H_
