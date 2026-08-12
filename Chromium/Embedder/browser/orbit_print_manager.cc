// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_print_manager.h"

#include "components/printing/browser/print_to_pdf/pdf_print_result.h"
#include "printing/mojom/print.mojom.h"

#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
#include "mojo/public/cpp/bindings/message.h"
#endif

namespace orbit {

namespace {
#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
constexpr char kUnexpectedPrintManagerCall[] =
    "Orbit Print Manager: unexpected Print Manager call";
#endif
}  // namespace

OrbitPrintManager::OrbitPrintManager(content::WebContents* web_contents)
    : printing::PrintManager(web_contents),
      content::WebContentsUserData<OrbitPrintManager>(*web_contents) {}

OrbitPrintManager::~OrbitPrintManager() = default;

// static
void OrbitPrintManager::BindPrintManagerHost(
    mojo::PendingAssociatedReceiver<printing::mojom::PrintManagerHost> receiver,
    content::RenderFrameHost* rfh) {
  auto* web_contents = content::WebContents::FromRenderFrameHost(rfh);
  if (!web_contents) {
    return;
  }
  auto* print_manager = OrbitPrintManager::FromWebContents(web_contents);
  if (!print_manager) {
    return;
  }
  print_manager->BindReceiver(std::move(receiver), rfh);
}

void OrbitPrintManager::PrintToPdf(
    content::RenderFrameHost* rfh,
    const std::string& page_ranges,
    printing::mojom::PrintPagesParamsPtr print_pages_params,
    print_to_pdf::PdfPrintJob::PrintToPdfCallback callback) {
  print_to_pdf::PdfPrintJob::StartJob(web_contents(), rfh, GetPrintRenderFrame(rfh),
                                      page_ranges, std::move(print_pages_params),
                                      std::move(callback));
}

void OrbitPrintManager::GetDefaultPrintSettings(GetDefaultPrintSettingsCallback callback) {
  std::move(callback).Run(nullptr);
}

void OrbitPrintManager::ScriptedPrint(printing::mojom::ScriptedPrintParamsPtr params,
                                      ScriptedPrintCallback callback) {
  std::move(callback).Run(nullptr);
}

#if BUILDFLAG(ENABLE_PRINT_PREVIEW)
void OrbitPrintManager::GetPrintPreviewParams(GetPrintPreviewParamsCallback callback) {
  mojo::ReportBadMessage(kUnexpectedPrintManagerCall);
}

void OrbitPrintManager::SetupScriptedPrintPreview(SetupScriptedPrintPreviewCallback callback) {
  std::move(callback).Run();
}

void OrbitPrintManager::ShowScriptedPrintPreview() {}

void OrbitPrintManager::RequestPrintPreview(
    printing::mojom::RequestPrintPreviewParamsPtr params) {
  mojo::ReportBadMessage(kUnexpectedPrintManagerCall);
}

void OrbitPrintManager::CheckForCancel(const base::UnguessableToken& preview_ui_id,
                                       int32_t request_id,
                                       CheckForCancelCallback callback) {
  mojo::ReportBadMessage(kUnexpectedPrintManagerCall);
}

void OrbitPrintManager::SetAccessibilityTree(int32_t cookie,
                                             const ui::AXTreeUpdate& accessibility_tree) {
  mojo::ReportBadMessage(kUnexpectedPrintManagerCall);
}
#endif  // BUILDFLAG(ENABLE_PRINT_PREVIEW)

#if BUILDFLAG(IS_ANDROID)
void OrbitPrintManager::SetupScriptedPrintAndroid(SetupScriptedPrintAndroidCallback callback) {
  std::move(callback).Run();
}

void OrbitPrintManager::PdfWritingDone(int page_count) {}
#endif

WEB_CONTENTS_USER_DATA_KEY_IMPL(OrbitPrintManager);

}  // namespace orbit
