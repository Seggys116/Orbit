// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_native_message_port_dispatcher.h"

#include <utility>

#include "base/functional/bind.h"
#include "base/task/single_thread_task_runner.h"
#include "extensions/browser/api/messaging/native_message_port.h"

namespace orbit {

OrbitNativeMessagePortDispatcher::OrbitNativeMessagePortDispatcher(
    std::unique_ptr<extensions::NativeMessageHost> host,
    base::WeakPtr<extensions::NativeMessagePort> port,
    scoped_refptr<base::SingleThreadTaskRunner> message_service_task_runner)
    : host_(std::move(host)),
      port_(port),
      message_service_task_runner_(std::move(message_service_task_runner)),
      host_task_runner_(host_->task_runner()) {
  DCHECK(message_service_task_runner_->BelongsToCurrentThread());
  host_task_runner_->PostTask(
      FROM_HERE, base::BindOnce(&extensions::NativeMessageHost::Start,
                                base::Unretained(host_.get()),
                                base::Unretained(this)));
}

OrbitNativeMessagePortDispatcher::~OrbitNativeMessagePortDispatcher() {
  DCHECK(host_task_runner_->BelongsToCurrentThread());
}

void OrbitNativeMessagePortDispatcher::DispatchOnMessage(
    const std::string& message) {
  DCHECK(message_service_task_runner_->BelongsToCurrentThread());
  host_task_runner_->PostTask(
      FROM_HERE, base::BindOnce(&extensions::NativeMessageHost::OnMessage,
                                base::Unretained(host_.get()), message));
}

void OrbitNativeMessagePortDispatcher::PostMessageFromNativeHost(
    const std::string& message) {
  DCHECK(host_task_runner_->BelongsToCurrentThread());
  message_service_task_runner_->PostTask(
      FROM_HERE,
      base::BindOnce(&extensions::NativeMessagePort::PostMessageFromNativeHost,
                     port_, message));
}

void OrbitNativeMessagePortDispatcher::CloseChannel(
    const std::string& error_message) {
  DCHECK(host_task_runner_->BelongsToCurrentThread());
  message_service_task_runner_->PostTask(
      FROM_HERE, base::BindOnce(&extensions::NativeMessagePort::CloseChannel,
                                port_, error_message));
}

}  // namespace orbit
