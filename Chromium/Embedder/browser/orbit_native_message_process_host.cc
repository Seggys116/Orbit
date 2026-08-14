// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_native_message_process_host.h"

#include <stddef.h>
#include <stdint.h>

#include <utility>

#include "base/compiler_specific.h"
#include "base/containers/span.h"
#include "base/functional/bind.h"
#include "base/logging.h"
#include "base/memory/ptr_util.h"
#include "base/numerics/safe_conversions.h"
#include "base/process/kill.h"
#include "base/task/thread_pool.h"
#include "content/public/browser/browser_task_traits.h"
#include "content/public/browser/browser_thread.h"
#include "extensions/common/constants.h"
#include "net/base/file_stream.h"
#include "net/base/io_buffer.h"
#include "url/gurl.h"

namespace orbit {

namespace {

// Caps what a misbehaving host can make Orbit allocate.
constexpr size_t kMaximumNativeMessageSize = 1024 * 1024;
constexpr size_t kMessageHeaderSize = 4;
constexpr size_t kReadBufferSize = 4096;

}  // namespace

OrbitNativeMessageProcessHost::OrbitNativeMessageProcessHost(
    const extensions::ExtensionId& source_extension_id,
    const std::string& native_host_name,
    std::unique_ptr<OrbitNativeProcessLauncher> launcher)
    : source_extension_id_(source_extension_id),
      native_host_name_(native_host_name),
      launcher_(std::move(launcher)),
      task_runner_(content::GetIOThreadTaskRunner({})) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
}

OrbitNativeMessageProcessHost::~OrbitNativeMessageProcessHost() {
  DCHECK(task_runner_->BelongsToCurrentThread());

  if (process_.IsValid()) {
    // EnsureProcessTerminated() can block on macOS.
    base::ThreadPool::PostTask(
        FROM_HERE, {base::MayBlock(), base::TaskPriority::BEST_EFFORT},
        base::BindOnce(&base::EnsureProcessTerminated, std::move(process_)));
  }
}

// static
std::unique_ptr<extensions::NativeMessageHost>
OrbitNativeMessageProcessHost::Create(
    const extensions::ExtensionId& source_extension_id,
    const std::string& native_host_name,
    bool allow_user_level_hosts) {
  DCHECK_CURRENTLY_ON(content::BrowserThread::UI);
  return base::WrapUnique(new OrbitNativeMessageProcessHost(
      source_extension_id, native_host_name,
      std::make_unique<OrbitNativeProcessLauncher>(allow_user_level_hosts)));
}

void OrbitNativeMessageProcessHost::Start(Client* client) {
  DCHECK(task_runner_->BelongsToCurrentThread());
  DCHECK(!client_);
  client_ = client;
  task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&OrbitNativeMessageProcessHost::LaunchHostProcess,
                     weak_factory_.GetWeakPtr()));
}

scoped_refptr<base::SingleThreadTaskRunner>
OrbitNativeMessageProcessHost::task_runner() const {
  return task_runner_;
}

void OrbitNativeMessageProcessHost::LaunchHostProcess() {
  DCHECK(task_runner_->BelongsToCurrentThread());
  GURL origin(std::string(extensions::kExtensionScheme) + "://" +
              source_extension_id_);
  launcher_->Launch(
      origin, native_host_name_,
      base::BindOnce(&OrbitNativeMessageProcessHost::OnHostProcessLaunched,
                     weak_factory_.GetWeakPtr()));
}

void OrbitNativeMessageProcessHost::OnHostProcessLaunched(
    OrbitNativeProcessLauncher::LaunchResult result,
    base::Process process,
    base::PlatformFile read_file,
    std::unique_ptr<net::FileStream> read_stream,
    std::unique_ptr<net::FileStream> write_stream) {
  DCHECK(task_runner_->BelongsToCurrentThread());

  switch (result) {
    case OrbitNativeProcessLauncher::LaunchResult::kInvalidName:
      Close(kInvalidNameError);
      return;
    case OrbitNativeProcessLauncher::LaunchResult::kNotFound:
      Close(kNotFoundError);
      return;
    case OrbitNativeProcessLauncher::LaunchResult::kForbidden:
      Close(kForbiddenError);
      return;
    case OrbitNativeProcessLauncher::LaunchResult::kFailedToStart:
      Close(kFailedToStartError);
      return;
    case OrbitNativeProcessLauncher::LaunchResult::kSuccess:
      break;
  }

  process_ = std::move(process);
  // `read_stream` owns `read_file`; the raw descriptor is what
  // FileDescriptorWatcher needs.
  read_file_ = read_file;
  read_stream_ = std::move(read_stream);
  write_stream_ = std::move(write_stream);

  WaitRead();
  DoWrite();
}

void OrbitNativeMessageProcessHost::OnMessage(const std::string& json) {
  DCHECK(task_runner_->BelongsToCurrentThread());

  if (closed_) {
    return;
  }

  scoped_refptr<net::IOBufferWithSize> buffer =
      base::MakeRefCounted<net::IOBufferWithSize>(json.size() +
                                                  kMessageHeaderSize);

  static_assert(sizeof(uint32_t) == kMessageHeaderSize,
                "kMessageHeaderSize is incorrect");
  const uint32_t message_size = base::checked_cast<uint32_t>(json.size());
  UNSAFE_TODO(memcpy(buffer->data(),
                     reinterpret_cast<const char*>(&message_size),
                     kMessageHeaderSize));
  buffer->span()
      .subspan(kMessageHeaderSize)
      .copy_from_nonoverlapping(base::as_byte_span(json));

  write_queue_.push(buffer);

  // The extension can post before the host has launched; OnHostProcessLaunched
  // drains the queue in that case.
  if (write_stream_) {
    DoWrite();
  }
}

void OrbitNativeMessageProcessHost::WaitRead() {
  if (closed_) {
    return;
  }
  DCHECK(!read_pending_);

  // FileStream::Read() blocks a pool thread on POSIX, so wait for readability
  // first rather than parking a thread per host.
  if (!read_controller_) {
    read_controller_ = base::FileDescriptorWatcher::WatchReadable(
        read_file_, base::BindRepeating(&OrbitNativeMessageProcessHost::DoRead,
                                        base::Unretained(this)));
  }
}

void OrbitNativeMessageProcessHost::DoRead() {
  DCHECK(task_runner_->BelongsToCurrentThread());

  while (!closed_ && !read_pending_) {
    read_buffer_ = base::MakeRefCounted<net::IOBufferWithSize>(kReadBufferSize);
    HandleReadResult(read_stream_->Read(
        read_buffer_.get(), kReadBufferSize,
        base::BindOnce(&OrbitNativeMessageProcessHost::OnRead,
                       weak_factory_.GetWeakPtr())));
  }
}

void OrbitNativeMessageProcessHost::OnRead(
    base::expected<base::ByteSize, net::Error> result) {
  DCHECK(task_runner_->BelongsToCurrentThread());
  DCHECK(read_pending_);
  read_pending_ = false;

  HandleReadResult(result);
  WaitRead();
}

void OrbitNativeMessageProcessHost::HandleReadResult(
    base::expected<base::ByteSize, net::Error> result) {
  DCHECK(task_runner_->BelongsToCurrentThread());

  if (closed_) {
    return;
  }

  if (result.has_value()) {
    if (result->is_positive()) {
      ProcessIncomingData(read_buffer_->data(),
                          base::checked_cast<int>(result->InBytes()));
    } else {
      Close(kNativeHostExited);
    }
  } else if (result.error() == net::ERR_IO_PENDING) {
    read_pending_ = true;
  } else if (result.error() == net::ERR_CONNECTION_RESET) {
    Close(kNativeHostExited);
  } else {
    Close(kHostInputOutputError);
  }
}

void OrbitNativeMessageProcessHost::ProcessIncomingData(const char* data,
                                                        int data_size) {
  DCHECK(task_runner_->BelongsToCurrentThread());

  incoming_data_.append(data, data_size);

  while (true) {
    if (incoming_data_.size() < kMessageHeaderSize) {
      return;
    }

    size_t message_size =
        *UNSAFE_TODO(reinterpret_cast<const uint32_t*>(incoming_data_.data()));

    if (message_size > kMaximumNativeMessageSize) {
      LOG(ERROR) << "Native messaging host " << native_host_name_
                 << " sent a " << message_size << " byte message.";
      Close(kHostInputOutputError);
      return;
    }

    if (incoming_data_.size() < message_size + kMessageHeaderSize) {
      return;
    }

    client_->PostMessageFromNativeHost(
        incoming_data_.substr(kMessageHeaderSize, message_size));

    incoming_data_.erase(0, kMessageHeaderSize + message_size);
  }
}

void OrbitNativeMessageProcessHost::DoWrite() {
  DCHECK(task_runner_->BelongsToCurrentThread());

  while (!write_pending_ && !closed_) {
    if (!current_write_buffer_.get() ||
        !current_write_buffer_->BytesRemaining()) {
      if (write_queue_.empty()) {
        return;
      }
      scoped_refptr<net::IOBufferWithSize> buffer =
          std::move(write_queue_.front());
      int buffer_size = buffer->size();
      current_write_buffer_ = base::MakeRefCounted<net::DrainableIOBuffer>(
          std::move(buffer), buffer_size);
      write_queue_.pop();
    }

    HandleWriteResult(write_stream_->Write(
        current_write_buffer_.get(), current_write_buffer_->BytesRemaining(),
        base::BindOnce(&OrbitNativeMessageProcessHost::OnWritten,
                       weak_factory_.GetWeakPtr())));
  }
}

void OrbitNativeMessageProcessHost::HandleWriteResult(
    base::expected<base::ByteSize, net::Error> result) {
  DCHECK(task_runner_->BelongsToCurrentThread());

  if (!result.has_value()) {
    if (result.error() == net::ERR_IO_PENDING) {
      write_pending_ = true;
    } else {
      LOG(ERROR) << "Error writing to native messaging host: "
                 << result.error();
      Close(kHostInputOutputError);
    }
    return;
  }

  if (result->is_zero()) {
    LOG(ERROR) << "Unexpected zero-length write to native messaging host.";
    Close(kHostInputOutputError);
    return;
  }

  current_write_buffer_->DidConsume(base::checked_cast<int>(result->InBytes()));
}

void OrbitNativeMessageProcessHost::OnWritten(
    base::expected<base::ByteSize, net::Error> result) {
  DCHECK(task_runner_->BelongsToCurrentThread());
  DCHECK(write_pending_);
  write_pending_ = false;

  HandleWriteResult(result);
  DoWrite();
}

void OrbitNativeMessageProcessHost::Close(const std::string& error_message) {
  DCHECK(task_runner_->BelongsToCurrentThread());

  if (closed_) {
    return;
  }
  closed_ = true;
  read_controller_.reset();
  read_stream_.reset();
  write_stream_.reset();
  client_->CloseChannel(error_message);
}

}  // namespace orbit
