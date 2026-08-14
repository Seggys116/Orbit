// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGE_PORT_DISPATCHER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGE_PORT_DISPATCHER_H_

#include <memory>
#include <string>

#include "base/memory/scoped_refptr.h"
#include "base/memory/weak_ptr.h"
#include "extensions/browser/api/messaging/native_message_host.h"
#include "extensions/browser/api/messaging/native_message_port_dispatcher.h"

namespace base {
class SingleThreadTaskRunner;
}

namespace extensions {
class NativeMessagePort;
}

namespace orbit {

// Hops between the host's task runner (the IO thread) and MessageService's
// (the UI thread). Host methods run on the former, port methods on the latter.
class OrbitNativeMessagePortDispatcher
    : public extensions::NativeMessagePortDispatcher,
      public extensions::NativeMessageHost::Client {
 public:
  OrbitNativeMessagePortDispatcher(
      std::unique_ptr<extensions::NativeMessageHost> host,
      base::WeakPtr<extensions::NativeMessagePort> port,
      scoped_refptr<base::SingleThreadTaskRunner> message_service_task_runner);
  OrbitNativeMessagePortDispatcher(const OrbitNativeMessagePortDispatcher&) =
      delete;
  OrbitNativeMessagePortDispatcher& operator=(
      const OrbitNativeMessagePortDispatcher&) = delete;
  ~OrbitNativeMessagePortDispatcher() override;

  // extensions::NativeMessagePortDispatcher:
  void DispatchOnMessage(const std::string& message) override;

  // extensions::NativeMessageHost::Client:
  void PostMessageFromNativeHost(const std::string& message) override;
  void CloseChannel(const std::string& error_message) override;

 private:
  std::unique_ptr<extensions::NativeMessageHost> host_;
  base::WeakPtr<extensions::NativeMessagePort> port_;
  scoped_refptr<base::SingleThreadTaskRunner> message_service_task_runner_;
  scoped_refptr<base::SingleThreadTaskRunner> host_task_runner_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_NATIVE_MESSAGE_PORT_DISPATCHER_H_
