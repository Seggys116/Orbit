// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_native_process_launcher.h"

#include <unistd.h>

#include <utility>

#include "base/base_paths.h"
#include "base/command_line.h"
#include "base/files/file_util.h"
#include "base/files/scoped_file.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/path_service.h"
#include "base/posix/eintr_wrapper.h"
#include "base/process/kill.h"
#include "base/process/launch.h"
#include "base/task/task_runner.h"
#include "base/task/thread_pool.h"
#include "net/base/file_stream.h"
#include "orbit/browser/orbit_native_messaging_host_manifest.h"
#include "orbit/common/orbit_user_data_dir.h"

namespace orbit {

namespace {

constexpr char kManifestDirName[] = "NativeMessagingHosts";

void TerminateNativeProcess(base::Process native_process) {
  // EnsureProcessTerminated() can block on macOS.
  base::ThreadPool::PostTask(FROM_HERE,
                             {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
                              base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
                             base::BindOnce(&base::EnsureProcessTerminated,
                                            std::move(native_process)));
}

}  // namespace

OrbitNativeProcessLauncher::ProcessState::ProcessState(
    base::Process process,
    base::ScopedPlatformFile read_file,
    base::ScopedPlatformFile write_file)
    : process(std::move(process)),
      read_file(std::move(read_file)),
      write_file(std::move(write_file)) {}
OrbitNativeProcessLauncher::ProcessState::ProcessState(
    ProcessState&&) noexcept = default;
OrbitNativeProcessLauncher::ProcessState&
OrbitNativeProcessLauncher::ProcessState::operator=(ProcessState&&) noexcept =
    default;
OrbitNativeProcessLauncher::ProcessState::~ProcessState() = default;

OrbitNativeProcessLauncher::BackgroundLaunchResult::BackgroundLaunchResult(
    LaunchResult result)
    : result(result) {}
OrbitNativeProcessLauncher::BackgroundLaunchResult::BackgroundLaunchResult(
    ProcessState process_state)
    : result(LaunchResult::kSuccess), process_state(std::move(process_state)) {}
OrbitNativeProcessLauncher::BackgroundLaunchResult::BackgroundLaunchResult(
    BackgroundLaunchResult&&) noexcept = default;
OrbitNativeProcessLauncher::BackgroundLaunchResult&
OrbitNativeProcessLauncher::BackgroundLaunchResult::operator=(
    BackgroundLaunchResult&&) noexcept = default;
OrbitNativeProcessLauncher::BackgroundLaunchResult::~BackgroundLaunchResult() =
    default;

OrbitNativeProcessLauncher::OrbitNativeProcessLauncher(
    bool allow_user_level_hosts)
    : allow_user_level_hosts_(allow_user_level_hosts) {}

OrbitNativeProcessLauncher::~OrbitNativeProcessLauncher() = default;

// static
std::vector<base::FilePath> OrbitNativeProcessLauncher::ManifestSearchDirs(
    bool allow_user_level_hosts) {
  std::vector<base::FilePath> dirs;

  if (allow_user_level_hosts) {
    dirs.push_back(ResolveOrbitUserDataDir().Append(kManifestDirName));

    base::FilePath app_data;
    if (base::PathService::Get(base::DIR_APP_DATA, &app_data)) {
      dirs.push_back(app_data.Append("Google")
                         .Append("Chrome")
                         .Append(kManifestDirName));
      dirs.push_back(app_data.Append("Chromium").Append(kManifestDirName));
    }
  }

  dirs.emplace_back("/Library/Application Support/Orbit/NativeMessagingHosts");
  dirs.emplace_back("/Library/Google/Chrome/NativeMessagingHosts");
  dirs.emplace_back(
      "/Library/Application Support/Chromium/NativeMessagingHosts");

  return dirs;
}

// static
base::FilePath OrbitNativeProcessLauncher::FindManifest(
    const std::string& host_name,
    bool allow_user_level_hosts) {
  for (const base::FilePath& dir :
       ManifestSearchDirs(allow_user_level_hosts)) {
    base::FilePath path = dir.Append(host_name + ".json");
    if (base::PathExists(path)) {
      return path;
    }
  }
  return base::FilePath();
}

void OrbitNativeProcessLauncher::Launch(const GURL& origin,
                                        const std::string& native_host_name,
                                        LaunchedCallback callback) {
  DCHECK_CALLED_ON_VALID_SEQUENCE(sequence_checker_);
  base::ThreadPool::CreateTaskRunner(
      {base::TaskPriority::USER_VISIBLE,
       base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN, base::MayBlock()})
      ->PostTaskAndReplyWithResult(
          FROM_HERE,
          base::BindOnce(&LaunchInBackground, allow_user_level_hosts_, origin,
                         native_host_name),
          base::BindOnce(&OnProcessLaunched, weak_ptr_factory_.GetWeakPtr(),
                         std::move(callback)));
}

// static
OrbitNativeProcessLauncher::BackgroundLaunchResult
OrbitNativeProcessLauncher::LaunchInBackground(
    bool allow_user_level_hosts,
    const GURL& origin,
    const std::string& native_host_name) {
  if (!OrbitNativeMessagingHostManifest::IsValidName(native_host_name)) {
    return BackgroundLaunchResult(LaunchResult::kInvalidName);
  }

  base::FilePath manifest_path =
      FindManifest(native_host_name, allow_user_level_hosts);
  if (manifest_path.empty()) {
    LOG(WARNING) << "Can't find manifest for native messaging host "
                 << native_host_name;
    return BackgroundLaunchResult(LaunchResult::kNotFound);
  }

  std::string error_message;
  std::unique_ptr<OrbitNativeMessagingHostManifest> manifest =
      OrbitNativeMessagingHostManifest::Load(manifest_path, &error_message);
  if (!manifest) {
    LOG(WARNING) << "Failed to load manifest for native messaging host "
                 << native_host_name << ": " << error_message;
    return BackgroundLaunchResult(LaunchResult::kNotFound);
  }

  if (manifest->name() != native_host_name) {
    LOG(WARNING) << "Manifest for native messaging host " << native_host_name
                 << " declares a different name.";
    return BackgroundLaunchResult(LaunchResult::kNotFound);
  }

  if (!manifest->allowed_origins().MatchesSecurityOrigin(origin)) {
    return BackgroundLaunchResult(LaunchResult::kForbidden);
  }

  base::FilePath host_path = manifest->path();
  if (!host_path.IsAbsolute()) {
    LOG(WARNING) << "Native messaging host path must be absolute for "
                 << native_host_name;
    return BackgroundLaunchResult(LaunchResult::kNotFound);
  }
  if (!base::PathExists(host_path)) {
    LOG(WARNING) << "Found manifest but not the binary for native messaging "
                    "host "
                 << native_host_name << " at " << host_path.AsUTF8Unsafe();
    return BackgroundLaunchResult(LaunchResult::kNotFound);
  }

  base::CommandLine command_line(host_path);
  // The origin has to be the first argument, so no AppendSwitch* below it.
  command_line.AppendArg(origin.spec());

  base::LaunchOptions options;

  int read_pipe_fds[2] = {};
  if (HANDLE_EINTR(pipe(read_pipe_fds)) != 0) {
    LOG(ERROR) << "Bad read pipe";
    return BackgroundLaunchResult(LaunchResult::kFailedToStart);
  }
  base::ScopedFD read_pipe_read_fd(read_pipe_fds[0]);
  base::ScopedFD read_pipe_write_fd(read_pipe_fds[1]);
  options.fds_to_remap.emplace_back(read_pipe_write_fd.get(), STDOUT_FILENO);

  int write_pipe_fds[2] = {};
  if (HANDLE_EINTR(pipe(write_pipe_fds)) != 0) {
    LOG(ERROR) << "Bad write pipe";
    return BackgroundLaunchResult(LaunchResult::kFailedToStart);
  }
  base::ScopedFD write_pipe_read_fd(write_pipe_fds[0]);
  base::ScopedFD write_pipe_write_fd(write_pipe_fds[1]);
  options.fds_to_remap.emplace_back(write_pipe_read_fd.get(), STDIN_FILENO);

  options.current_directory = host_path.DirName();
  // A third-party binary must not inherit Orbit's TCC attributions.
  options.disclaim_responsibility = true;

  base::Process process = base::LaunchProcess(command_line, options);
  if (!process.IsValid()) {
    LOG(ERROR) << "Failed to launch native messaging host "
               << native_host_name;
    return BackgroundLaunchResult(LaunchResult::kFailedToStart);
  }

  write_pipe_read_fd.reset();
  read_pipe_write_fd.reset();

  return BackgroundLaunchResult(ProcessState(std::move(process),
                                             std::move(read_pipe_read_fd),
                                             std::move(write_pipe_write_fd)));
}

// static
void OrbitNativeProcessLauncher::OnProcessLaunched(
    base::WeakPtr<OrbitNativeProcessLauncher> weak_this,
    LaunchedCallback callback,
    BackgroundLaunchResult result) {
  if (!weak_this) {
    // Cancelled: reap the host and close the pipes off the IO thread.
    if (result.process_state.has_value()) {
      TerminateNativeProcess(std::move(result.process_state->process));
      base::ThreadPool::PostTask(
          FROM_HERE,
          {base::MayBlock(), base::TaskPriority::BEST_EFFORT,
           base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN},
          base::BindOnce([](base::ScopedPlatformFile read_file,
                            base::ScopedPlatformFile write_file) {},
                         std::move(result.process_state->read_file),
                         std::move(result.process_state->write_file)));
    }
    return;
  }

  DCHECK_CALLED_ON_VALID_SEQUENCE(weak_this->sequence_checker_);

  if (result.result != LaunchResult::kSuccess) {
    std::move(callback).Run(result.result, base::Process(),
                            base::kInvalidPlatformFile, nullptr, nullptr);
    return;
  }

  scoped_refptr<base::TaskRunner> stream_task_runner =
      base::ThreadPool::CreateTaskRunner(
          {base::TaskPriority::USER_VISIBLE,
           base::TaskShutdownBehavior::CONTINUE_ON_SHUTDOWN,
           base::MayBlock()});

  base::ScopedPlatformFile read_file =
      std::move(result.process_state->read_file);
  base::PlatformFile read_file_unowned = read_file.get();

  std::move(callback).Run(
      LaunchResult::kSuccess, std::move(result.process_state->process),
      read_file_unowned,
      std::make_unique<net::FileStream>(base::File(std::move(read_file)),
                                        stream_task_runner),
      std::make_unique<net::FileStream>(
          base::File(std::move(result.process_state->write_file)),
          stream_task_runner));
}

}  // namespace orbit
