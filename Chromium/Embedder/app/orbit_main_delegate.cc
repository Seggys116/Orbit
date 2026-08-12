// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_main_delegate.h"

#include "base/command_line.h"
#include "base/environment.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "content/public/common/content_switches.h"
#include "orbit/browser/orbit_content_browser_client.h"
#include "orbit/common/orbit_content_client.h"
#include "orbit/common/orbit_user_data_dir.h"
#include "orbit/renderer/orbit_content_renderer_client.h"
#include "orbit_paths_mac.h"
#include "ui/base/resource/resource_bundle.h"

namespace orbit {

namespace {

// Recognised only for the browser-process (empty --type) invocation: lets a
// harness prove the dlopen -> ContentMain -> RunProcess chain executed.
constexpr char kOrbitSelfTestSwitch[] = "orbit-selftest";

}  // namespace

OrbitMainDelegate::OrbitMainDelegate() = default;
OrbitMainDelegate::~OrbitMainDelegate() = default;

std::optional<int> OrbitMainDelegate::BasicStartupComplete() {
  // Must run before anything can read the profile directory or a subprocess
  // launch computes sandbox params against the production profile.
  ApplyPendingOrbitUserDataDirToCommandLine();
  return std::nullopt;
}

void OrbitMainDelegate::PreSandboxStartup() {
  // Every process constructs its own delegate, so this runs once per
  // process. Blink reads UA style sheets via ui::ResourceBundle; without
  // this init, CSS renders as plain text (every process, including
  // sandboxed helpers, must load the pak, not just the browser).
  const std::string process_type =
      base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
          switches::kProcessType);

  const base::FilePath pak_path = GetResourcesPakFilePath();
  const bool pak_exists = base::PathExists(pak_path);
  LOG(ERROR) << "orbit: PreSandboxStartup process_type='" << process_type
             << "' pak_path=" << pak_path << " exists=" << pak_exists;
  ui::ResourceBundle::InitSharedInstanceWithPakPath(pak_path);
  LOG(ERROR) << "orbit: PreSandboxStartup process_type='" << process_type
             << "' ResourceBundle initialised, HasSharedInstance="
             << ui::ResourceBundle::HasSharedInstance();
}

std::variant<int, content::MainFunctionParams> OrbitMainDelegate::RunProcess(
    const std::string& process_type,
    content::MainFunctionParams main_function_params) {
  if (process_type.empty() &&
      main_function_params.command_line->HasSwitch(kOrbitSelfTestSwitch)) {
    LOG(INFO) << "orbit-selftest: OrbitMain -> ContentMain -> "
                 "ContentMainRunnerImpl::Run -> OrbitMainDelegate::RunProcess "
                 "reached for the browser process. Exiting 0.";
    return 0;
  }
  return std::move(main_function_params);
}

content::ContentClient* OrbitMainDelegate::CreateContentClient() {
  // Base ContentClient's GetDataResource*()/GetLocalizedString() are stubs
  // that never consult ui::ResourceBundle; without this override the UA
  // stylesheet still resolves to an empty string.
  content_client_ = std::make_unique<OrbitContentClient>();
  return content_client_.get();
}

content::ContentBrowserClient* OrbitMainDelegate::CreateContentBrowserClient() {
  browser_client_ = std::make_unique<OrbitContentBrowserClient>();
  return browser_client_.get();
}

content::ContentRendererClient*
OrbitMainDelegate::CreateContentRendererClient() {
  renderer_client_ = std::make_unique<OrbitContentRendererClient>();
  return renderer_client_.get();
}

}  // namespace orbit
