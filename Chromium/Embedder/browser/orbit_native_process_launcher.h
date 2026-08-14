// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_PROCESS_LAUNCHER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_PROCESS_LAUNCHER_H_

#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "base/files/file_path.h"
#include "base/files/platform_file.h"
#include "base/functional/callback.h"
#include "base/memory/weak_ptr.h"
#include "base/process/process.h"
#include "base/sequence_checker.h"
#include "url/gurl.h"

namespace net {
class FileStream;
}

namespace orbit {

// Finds a native messaging host manifest, then launches the host with its
// stdin/stdout wired to a pair of pipes. Lives on the IO thread; destroying an
// instance cancels an in-flight launch and reaps the process.
class OrbitNativeProcessLauncher {
 public:
  enum class LaunchResult {
    kSuccess,
    kInvalidName,
    kNotFound,
    kForbidden,
    kFailedToStart,
  };

  // `read_file` is the descriptor owned by `read_stream`.
  using LaunchedCallback =
      base::OnceCallback<void(LaunchResult result,
                              base::Process process,
                              base::PlatformFile read_file,
                              std::unique_ptr<net::FileStream> read_stream,
                              std::unique_ptr<net::FileStream> write_stream)>;

  explicit OrbitNativeProcessLauncher(bool allow_user_level_hosts);
  OrbitNativeProcessLauncher(const OrbitNativeProcessLauncher&) = delete;
  OrbitNativeProcessLauncher& operator=(const OrbitNativeProcessLauncher&) =
      delete;
  ~OrbitNativeProcessLauncher();

  void Launch(const GURL& origin,
              const std::string& native_host_name,
              LaunchedCallback callback);

  // Ordered highest-priority first. Orbit's own directories come first so an
  // Orbit-aware installer wins; the Chrome and Chromium directories follow
  // because that is where every shipping macOS host installs itself.
  static std::vector<base::FilePath> ManifestSearchDirs(
      bool allow_user_level_hosts);

  static base::FilePath FindManifest(const std::string& host_name,
                                     bool allow_user_level_hosts);

 private:
  struct ProcessState {
    ProcessState(base::Process process,
                 base::ScopedPlatformFile read_file,
                 base::ScopedPlatformFile write_file);
    ProcessState(ProcessState&&) noexcept;
    ProcessState& operator=(ProcessState&&) noexcept;
    ~ProcessState();

    base::Process process;
    base::ScopedPlatformFile read_file;   // The child's stdout.
    base::ScopedPlatformFile write_file;  // The child's stdin.
  };

  struct BackgroundLaunchResult {
    explicit BackgroundLaunchResult(LaunchResult result);
    explicit BackgroundLaunchResult(ProcessState process_state);
    BackgroundLaunchResult(BackgroundLaunchResult&&) noexcept;
    BackgroundLaunchResult& operator=(BackgroundLaunchResult&&) noexcept;
    ~BackgroundLaunchResult();

    LaunchResult result;
    std::optional<ProcessState> process_state;
  };

  static BackgroundLaunchResult LaunchInBackground(
      bool allow_user_level_hosts,
      const GURL& origin,
      const std::string& native_host_name);

  static void OnProcessLaunched(
      base::WeakPtr<OrbitNativeProcessLauncher> weak_this,
      LaunchedCallback callback,
      BackgroundLaunchResult result);

  const bool allow_user_level_hosts_;
  SEQUENCE_CHECKER(sequence_checker_);
  base::WeakPtrFactory<OrbitNativeProcessLauncher> weak_ptr_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_PROCESS_LAUNCHER_H_
