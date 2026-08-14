// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_messaging_delegate.h"

#include "content/public/browser/web_contents.h"
#include "extensions/browser/api/messaging/native_message_host.h"
#include "extensions/browser/api/messaging/native_message_port.h"
#include "orbit/browser/orbit_native_message_process_host.h"
#include "orbit/browser/orbit_tab_registry.h"

namespace orbit {

OrbitMessagingDelegate::OrbitMessagingDelegate() = default;
OrbitMessagingDelegate::~OrbitMessagingDelegate() = default;

extensions::MessagingDelegate::PolicyPermission
OrbitMessagingDelegate::IsNativeMessagingHostAllowed(
    content::BrowserContext* browser_context,
    const std::string& native_host_name) {
  // Orbit has no enterprise policy surface, so there is no blocklist and no
  // system-only restriction to apply.
  return PolicyPermission::ALLOW_ALL;
}

std::unique_ptr<extensions::MessagePort>
OrbitMessagingDelegate::CreateReceiverForNativeApp(
    content::BrowserContext* browser_context,
    base::WeakPtr<extensions::MessagePort::ChannelDelegate> channel_delegate,
    content::RenderFrameHost* source,
    const extensions::ExtensionId& extension_id,
    const extensions::PortId& receiver_port_id,
    const std::string& native_app_name,
    bool allow_user_level,
    std::string* error_out) {
  DCHECK(error_out);
  std::unique_ptr<extensions::NativeMessageHost> native_host =
      OrbitNativeMessageProcessHost::Create(extension_id, native_app_name,
                                            allow_user_level);
  if (!native_host) {
    *error_out = extensions::NativeMessageHost::kFailedToStartError;
    return nullptr;
  }
  return std::make_unique<extensions::NativeMessagePort>(
      channel_delegate, receiver_port_id, std::move(native_host));
}

std::optional<base::DictValue> OrbitMessagingDelegate::MaybeGetTabInfo(
    content::WebContents* web_contents) {
  const OrbitTabInfo* tab =
      OrbitTabRegistry::GetInstance().GetTabForWebContents(web_contents);
  if (!tab) {
    // Not a real Orbit tab: extension popups, options pages, and background
    // hosts are their own WebContents but never registered with OrbitTabRegistry.
    return std::nullopt;
  }
  // force_full_access, not extension-scrubbed: the extension being messaged
  // needs to see its own sender's real tab to decide whether to trust it,
  // matching ChromeMessagingDelegate::MaybeGetTabInfo's kDontScrubTab.
  return OrbitTabRegistry::GetInstance().CreateTabValue(
      *tab, /*extension=*/nullptr, /*force_full_access=*/true);
}

content::WebContents* OrbitMessagingDelegate::GetWebContentsByTabId(
    content::BrowserContext* browser_context,
    int tab_id) {
  const OrbitTabInfo* tab = OrbitTabRegistry::GetInstance().GetTab(tab_id);
  return tab ? tab->web_contents.get() : nullptr;
}

void OrbitMessagingDelegate::QueryIncognitoConnectability(
    content::BrowserContext* context,
    const extensions::Extension* extension,
    content::WebContents* web_contents,
    const GURL& url,
    base::OnceCallback<void(bool)> callback) {
  // Orbit has no incognito profile, so false here is a real answer, not a stub:
  // a normal-profile source can never be asking to connect from incognito.
  std::move(callback).Run(false);
}

}  // namespace orbit
