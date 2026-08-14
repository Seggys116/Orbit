// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGE_PROCESS_HOST_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGE_PROCESS_HOST_H_

#include <memory>
#include <string>

#include "base/byte_size.h"
#include "base/containers/queue.h"
#include "base/files/file_descriptor_watcher_posix.h"
#include "base/files/platform_file.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/process/process.h"
#include "base/task/single_thread_task_runner.h"
#include "base/types/expected.h"
#include "extensions/browser/api/messaging/native_message_host.h"
#include "extensions/common/extension_id.h"
#include "net/base/net_errors.h"
#include "orbit/browser/orbit_native_process_launcher.h"

namespace net {
class DrainableIOBuffer;
class FileStream;
class IOBuffer;
class IOBufferWithSize;
}  // namespace net

namespace orbit {

// Orbit's side of a chrome.runtime.connectNative channel: owns the host
// process and frames messages over its stdio pipes.
class OrbitNativeMessageProcessHost : public extensions::NativeMessageHost {
 public:
  OrbitNativeMessageProcessHost(const OrbitNativeMessageProcessHost&) = delete;
  OrbitNativeMessageProcessHost& operator=(
      const OrbitNativeMessageProcessHost&) = delete;
  ~OrbitNativeMessageProcessHost() override;

  static std::unique_ptr<extensions::NativeMessageHost> Create(
      const extensions::ExtensionId& source_extension_id,
      const std::string& native_host_name,
      bool allow_user_level_hosts);

  // extensions::NativeMessageHost:
  void OnMessage(const std::string& message) override;
  void Start(Client* client) override;
  scoped_refptr<base::SingleThreadTaskRunner> task_runner() const override;

 private:
  OrbitNativeMessageProcessHost(
      const extensions::ExtensionId& source_extension_id,
      const std::string& native_host_name,
      std::unique_ptr<OrbitNativeProcessLauncher> launcher);

  void LaunchHostProcess();
  void OnHostProcessLaunched(
      OrbitNativeProcessLauncher::LaunchResult result,
      base::Process process,
      base::PlatformFile read_file,
      std::unique_ptr<net::FileStream> read_stream,
      std::unique_ptr<net::FileStream> write_stream);

  void WaitRead();
  void DoRead();
  void OnRead(base::expected<base::ByteSize, net::Error> result);
  void HandleReadResult(base::expected<base::ByteSize, net::Error> result);
  void ProcessIncomingData(const char* data, int data_size);

  void DoWrite();
  void HandleWriteResult(base::expected<base::ByteSize, net::Error> result);
  void OnWritten(base::expected<base::ByteSize, net::Error> result);

  void Close(const std::string& error_message);

  raw_ptr<Client> client_ = nullptr;
  extensions::ExtensionId source_extension_id_;
  std::string native_host_name_;
  std::unique_ptr<OrbitNativeProcessLauncher> launcher_;
  bool closed_ = false;
  base::Process process_;

  std::unique_ptr<net::FileStream> read_stream_;
  base::PlatformFile read_file_ = base::kInvalidPlatformFile;
  std::unique_ptr<base::FileDescriptorWatcher::Controller> read_controller_;
  scoped_refptr<net::IOBuffer> read_buffer_;
  bool read_pending_ = false;
  std::string incoming_data_;

  std::unique_ptr<net::FileStream> write_stream_;
  base::queue<scoped_refptr<net::IOBufferWithSize>> write_queue_;
  scoped_refptr<net::DrainableIOBuffer> current_write_buffer_;
  bool write_pending_ = false;

  scoped_refptr<base::SingleThreadTaskRunner> task_runner_;
  base::WeakPtrFactory<OrbitNativeMessageProcessHost> weak_factory_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGE_PROCESS_HOST_H_
