// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.cookies.{get,getAll,set,remove,getAllCookieStores} via network::mojom::CookieManager.
// Hand-parses args() like orbit_tabs_api.h/orbit_action_api.h; onChanged is OrbitCookiesEventRouter, not here.

#ifndef ORBIT_EMBEDDER_BROWSER_API_COOKIES_ORBIT_COOKIES_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_COOKIES_ORBIT_COOKIES_API_H_

#include <optional>
#include <string>

#include "extensions/browser/extension_function.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "url/gurl.h"

namespace orbit {

class CookiesGetFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("cookies.get", COOKIES_GET)

 protected:
  ~CookiesGetFunction() override = default;
  ResponseAction Run() override;

 private:
  void GetCookieListCallback(const net::CookieAccessResultList& cookie_list,
                             const net::CookieAccessResultList& excluded_cookies);

  GURL url_;
  std::string name_;
};

class CookiesGetAllFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("cookies.getAll", COOKIES_GETALL)

  CookiesGetAllFunction();

 protected:
  ~CookiesGetAllFunction() override;
  ResponseAction Run() override;

 private:
  bool MatchesFilter(const net::CanonicalCookie& cookie) const;
  void GetAllCookiesCallback(const net::CookieList& cookie_list);
  void GetCookieListCallback(const net::CookieAccessResultList& cookie_list,
                             const net::CookieAccessResultList& excluded_cookies);

  // The getAll() filter fields, hand-parsed out of args()[0] in Run() since
  // details_ itself would have to outlive the async CookieManager round trip.
  std::optional<std::string> filter_name_;
  std::optional<std::string> filter_domain_;
  std::optional<std::string> filter_path_;
  std::optional<bool> filter_secure_;
  std::optional<bool> filter_session_;
};

class CookiesSetFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("cookies.set", COOKIES_SET)

 protected:
  ~CookiesSetFunction() override = default;
  ResponseAction Run() override;

 private:
  void SetCanonicalCookieCallback(net::CookieAccessResult set_cookie_result);
  void GetCookieListCallback(const net::CookieAccessResultList& cookie_list,
                             const net::CookieAccessResultList& excluded_cookies);

  enum State { kNoResponse, kSetCompleted, kGetCompleted };
  State state_ = kNoResponse;
  bool success_ = false;
  GURL url_;
  std::string name_;
};

class CookiesRemoveFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("cookies.remove", COOKIES_REMOVE)

 protected:
  ~CookiesRemoveFunction() override = default;
  ResponseAction Run() override;

 private:
  void RemoveCookieCallback(uint32_t num_deleted);

  GURL url_;
  std::string name_;
};

class CookiesGetAllCookieStoresFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("cookies.getAllCookieStores",
                             COOKIES_GETALLCOOKIESTORES)

 protected:
  ~CookiesGetAllCookieStoresFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_COOKIES_ORBIT_COOKIES_API_H_
