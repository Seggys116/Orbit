// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Backs runtime.connect/sendMessage's tab-targeted overloads via OrbitTabRegistry
// and runtime.connectNative/sendNativeMessage; the base class NOTIMPLEMENTED()s
// all of them.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_MESSAGING_DELEGATE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_MESSAGING_DELEGATE_H_

#include "extensions/browser/api/messaging/messaging_delegate.h"

namespace orbit {

class OrbitMessagingDelegate : public extensions::MessagingDelegate {
 public:
  OrbitMessagingDelegate();
  OrbitMessagingDelegate(const OrbitMessagingDelegate&) = delete;
  OrbitMessagingDelegate& operator=(const OrbitMessagingDelegate&) = delete;
  ~OrbitMessagingDelegate() override;

  // extensions::MessagingDelegate:
  PolicyPermission IsNativeMessagingHostAllowed(
      content::BrowserContext* browser_context,
      const std::string& native_host_name) override;
  std::unique_ptr<extensions::MessagePort> CreateReceiverForNativeApp(
      content::BrowserContext* browser_context,
      base::WeakPtr<extensions::MessagePort::ChannelDelegate> channel_delegate,
      content::RenderFrameHost* source,
      const extensions::ExtensionId& extension_id,
      const extensions::PortId& receiver_port_id,
      const std::string& native_app_name,
      bool allow_user_level,
      std::string* error_out) override;
  std::optional<base::DictValue> MaybeGetTabInfo(
      content::WebContents* web_contents) override;
  content::WebContents* GetWebContentsByTabId(
      content::BrowserContext* browser_context,
      int tab_id) override;
  void QueryIncognitoConnectability(
      content::BrowserContext* context,
      const extensions::Extension* extension,
      content::WebContents* web_contents,
      const GURL& url,
      base::OnceCallback<void(bool)> callback) override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_MESSAGING_DELEGATE_H_
