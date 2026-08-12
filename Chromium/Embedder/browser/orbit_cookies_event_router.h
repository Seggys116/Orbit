// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.cookies.onChanged via a CookieChangeListener bound to the default
// StoragePartition's CookieManager. Process-wide singleton, StartObserving()'d
// once OrbitBrowserContext exists and StopObserving()'d as it goes away.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_COOKIES_EVENT_ROUTER_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_COOKIES_EVENT_ROUTER_H_

#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "mojo/public/cpp/bindings/receiver.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

namespace content {
class BrowserContext;
}  // namespace content

namespace net {
struct CookieChangeInfo;
}  // namespace net

namespace orbit {

class OrbitCookiesEventRouter : public network::mojom::CookieChangeListener {
 public:
  static OrbitCookiesEventRouter& GetInstance();

  OrbitCookiesEventRouter(const OrbitCookiesEventRouter&) = delete;
  OrbitCookiesEventRouter& operator=(const OrbitCookiesEventRouter&) = delete;

  // Called once the single OrbitBrowserContext exists, and again (with
  // StopObserving) as it goes away -- see OrbitBrowserMainParts.
  void StartObserving(content::BrowserContext* browser_context);
  void StopObserving();

  // network::mojom::CookieChangeListener:
  void OnCookieChange(const net::CookieChangeInfo& change) override;

 private:
  friend class base::NoDestructor<OrbitCookiesEventRouter>;

  OrbitCookiesEventRouter();
  ~OrbitCookiesEventRouter() override;

  void BindToCookieManager();
  void OnConnectionError();

  raw_ptr<content::BrowserContext> browser_context_ = nullptr;
  mojo::Receiver<network::mojom::CookieChangeListener> receiver_{this};
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_COOKIES_EVENT_ROUTER_H_
