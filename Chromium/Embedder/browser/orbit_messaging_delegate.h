// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Backs runtime.connect/sendMessage's tab-targeted overloads via OrbitTabRegistry;
// the base class NOTIMPLEMENTED()s both, which fired on every content-script page load.

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
