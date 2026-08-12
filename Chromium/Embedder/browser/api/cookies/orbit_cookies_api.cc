// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_cookies_api.h"

#include <cmath>
#include <limits>
#include <memory>
#include <optional>
#include <string>
#include <utility>

#include "base/check_op.h"
#include "base/functional/bind.h"
#include "base/time/time.h"
#include "base/values.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "extensions/common/error_utils.h"
#include "extensions/common/extension.h"
#include "extensions/common/permissions/permissions_data.h"
#include "mojo/public/cpp/bindings/callback_helpers.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "net/cookies/cookie_util.h"
#include "orbit/browser/orbit_tab_registry.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"

namespace orbit {

namespace {

constexpr char kOnlyCookieStoreId[] = "0";

constexpr char kCookieSetFailedError[] =
    "Failed to parse or set cookie named \"*\".";
constexpr char kInvalidStoreIdError[] = "Invalid cookie store id: \"*\".";
constexpr char kInvalidUrlError[] = "Invalid url: \"*\".";
constexpr char kNoHostPermissionsError[] =
    "No host permissions for cookies at url: \"*\".";
constexpr char kNoCookieStoreError[] = "Cookie store is not available.";

network::mojom::CookieManager* CookieManagerFor(
    content::BrowserContext* browser_context) {
  if (!browser_context) {
    return nullptr;
  }
  content::StoragePartition* partition =
      browser_context->GetDefaultStoragePartition();
  return partition ? partition->GetCookieManagerForBrowserProcess() : nullptr;
}

bool CheckHostPermissions(const extensions::Extension* extension,
                          const GURL& url,
                          std::string* error) {
  if (!extension->permissions_data()->HasHostPermission(url)) {
    *error = extensions::ErrorUtils::FormatErrorMessage(
        kNoHostPermissionsError, url.spec());
    return false;
  }
  return true;
}

bool ParseUrl(const extensions::Extension* extension,
             const std::string& url_string,
             GURL* url,
             bool check_host_permissions,
             std::string* error) {
  *url = GURL(url_string);
  if (!url->is_valid()) {
    *error = extensions::ErrorUtils::FormatErrorMessage(kInvalidUrlError,
                                                        url_string);
    return false;
  }
  if (check_host_permissions && !CheckHostPermissions(extension, *url, error)) {
    return false;
  }
  return true;
}

// True (with `*error` untouched) if `store_id` names Orbit's one cookie
// store, i.e. is empty (defaulted) or exactly "0".
bool CheckStoreId(const std::string& store_id, std::string* error) {
  if (store_id.empty() || store_id == kOnlyCookieStoreId) {
    return true;
  }
  *error =
      extensions::ErrorUtils::FormatErrorMessage(kInvalidStoreIdError, store_id);
  return false;
}

std::string SameSiteToString(net::CookieSameSite same_site) {
  switch (same_site) {
    case net::CookieSameSite::NO_RESTRICTION:
      return "no_restriction";
    case net::CookieSameSite::LAX_MODE:
      return "lax";
    case net::CookieSameSite::STRICT_MODE:
      return "strict";
    case net::CookieSameSite::UNSPECIFIED:
      return "unspecified";
  }
  return "unspecified";
}

net::CookieSameSite SameSiteFromString(const std::string* value) {
  if (!value) {
    return net::CookieSameSite::UNSPECIFIED;
  }
  if (*value == "no_restriction") {
    return net::CookieSameSite::NO_RESTRICTION;
  }
  if (*value == "lax") {
    return net::CookieSameSite::LAX_MODE;
  }
  if (*value == "strict") {
    return net::CookieSameSite::STRICT_MODE;
  }
  return net::CookieSameSite::UNSPECIFIED;
}

base::DictValue CreateCookieValue(const net::CanonicalCookie& cookie) {
  base::DictValue dict;
  dict.Set("name", cookie.Name());
  dict.Set("value", cookie.Value());
  dict.Set("domain", cookie.Domain());
  dict.Set("hostOnly", net::cookie_util::DomainIsHostOnly(cookie.Domain()));
  dict.Set("path", cookie.Path());
  dict.Set("secure", cookie.SecureAttribute());
  dict.Set("httpOnly", cookie.IsHttpOnly());
  dict.Set("sameSite", SameSiteToString(cookie.SameSite()));
  dict.Set("session", !cookie.IsPersistent());
  if (cookie.IsPersistent()) {
    double expiration_date = cookie.ExpiryDate().InSecondsFSinceUnixEpoch();
    if (cookie.ExpiryDate().is_max() || !std::isfinite(expiration_date)) {
      expiration_date = std::numeric_limits<double>::max();
    }
    dict.Set("expirationDate", expiration_date);
  }
  dict.Set("storeId", kOnlyCookieStoreId);
  return dict;
}

// Mirrors cookies_helpers::GetURLFromCanonicalCookie: the URL implied by a
// cookie's domain/Secure attribute, used only to check host permissions -- never a real request.
GURL URLFromCanonicalCookie(const net::CanonicalCookie& cookie) {
  return net::cookie_util::CookieOriginToURL(cookie.Domain(),
                                             cookie.SecureAttribute());
}

// Mirrors cookies_helpers::MatchFilter::MatchesDomain: matches if `cookie_domain`
// is `filter_domain` or a subdomain of it, ignoring either's leading dot.
bool MatchesDomain(const std::string& cookie_domain,
                   std::string filter_domain) {
  if (net::cookie_util::DomainIsHostOnly(filter_domain)) {
    filter_domain.insert(0, ".");
  }
  std::string sub_domain(cookie_domain);
  if (!net::cookie_util::DomainIsHostOnly(sub_domain)) {
    sub_domain = sub_domain.substr(1);
  }
  for (sub_domain.insert(0, "."); sub_domain.length() >= filter_domain.length();) {
    if (sub_domain == filter_domain) {
      return true;
    }
    const size_t next_dot = sub_domain.find('.', 1);
    sub_domain.erase(0, next_dot);
  }
  return false;
}

}  // namespace

ExtensionFunction::ResponseAction CookiesGetFunction::Run() {
  const base::DictValue* details = args().empty() ? nullptr : args()[0].GetIfDict();
  EXTENSION_FUNCTION_VALIDATE(details);

  const std::string* url_string = details->FindString("url");
  const std::string* name = details->FindString("name");
  EXTENSION_FUNCTION_VALIDATE(url_string && name);
  name_ = *name;

  std::string error;
  if (!ParseUrl(extension(), *url_string, &url_, /*check_host_permissions=*/true,
               &error)) {
    return RespondNow(Error(std::move(error)));
  }

  const std::string* store_id = details->FindString("storeId");
  if (!CheckStoreId(store_id ? *store_id : std::string(), &error)) {
    return RespondNow(Error(std::move(error)));
  }

  network::mojom::CookieManager* cookie_manager = CookieManagerFor(browser_context());
  if (!cookie_manager) {
    return RespondNow(Error(kNoCookieStoreError));
  }

  cookie_manager->GetCookieList(
      url_, net::CookieOptions::MakeAllInclusive(),
      net::CookiePartitionKeyCollection(),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
          base::BindOnce(&CookiesGetFunction::GetCookieListCallback, this),
          net::CookieAccessResultList(), net::CookieAccessResultList()));
  return RespondLater();
}

void CookiesGetFunction::GetCookieListCallback(
    const net::CookieAccessResultList& cookie_list,
    const net::CookieAccessResultList& excluded_cookies) {
  for (const net::CookieWithAccessResult& entry : cookie_list) {
    if (entry.cookie.Name() == name_) {
      Respond(WithArguments(CreateCookieValue(entry.cookie)));
      return;
    }
  }
  Respond(WithArguments(base::Value()));
}

CookiesGetAllFunction::CookiesGetAllFunction() = default;

CookiesGetAllFunction::~CookiesGetAllFunction() = default;

ExtensionFunction::ResponseAction CookiesGetAllFunction::Run() {
  const base::DictValue* details = args().empty() ? nullptr : args()[0].GetIfDict();

  GURL url;
  bool have_url = false;
  std::string error;
  if (details) {
    if (const std::string* url_string = details->FindString("url")) {
      if (!ParseUrl(extension(), *url_string, &url, /*check_host_permissions=*/false,
                   &error)) {
        return RespondNow(Error(std::move(error)));
      }
      have_url = true;
    }
    if (const std::string* name = details->FindString("name")) {
      filter_name_ = *name;
    }
    if (const std::string* domain = details->FindString("domain")) {
      filter_domain_ = *domain;
    }
    if (const std::string* path = details->FindString("path")) {
      filter_path_ = *path;
    }
    filter_secure_ = details->FindBool("secure");
    filter_session_ = details->FindBool("session");

    const std::string* store_id = details->FindString("storeId");
    if (!CheckStoreId(store_id ? *store_id : std::string(), &error)) {
      return RespondNow(Error(std::move(error)));
    }
  }

  network::mojom::CookieManager* cookie_manager = CookieManagerFor(browser_context());
  if (!cookie_manager) {
    return RespondNow(Error(kNoCookieStoreError));
  }

  if (have_url) {
    cookie_manager->GetCookieList(
        url, net::CookieOptions::MakeAllInclusive(),
        net::CookiePartitionKeyCollection(),
        mojo::WrapCallbackWithDefaultInvokeIfNotRun(
            base::BindOnce(&CookiesGetAllFunction::GetCookieListCallback, this),
            net::CookieAccessResultList(), net::CookieAccessResultList()));
  } else {
    cookie_manager->GetAllCookies(mojo::WrapCallbackWithDefaultInvokeIfNotRun(
        base::BindOnce(&CookiesGetAllFunction::GetAllCookiesCallback, this),
        net::CookieList()));
  }
  return RespondLater();
}

bool CookiesGetAllFunction::MatchesFilter(const net::CanonicalCookie& cookie) const {
  if (!extension()->permissions_data()->HasHostPermission(
          URLFromCanonicalCookie(cookie))) {
    return false;
  }
  if (filter_name_ && *filter_name_ != cookie.Name()) {
    return false;
  }
  if (filter_domain_ && !MatchesDomain(cookie.Domain(), *filter_domain_)) {
    return false;
  }
  if (filter_path_ && *filter_path_ != cookie.Path()) {
    return false;
  }
  if (filter_secure_ && *filter_secure_ != cookie.SecureAttribute()) {
    return false;
  }
  if (filter_session_ && *filter_session_ != !cookie.IsPersistent()) {
    return false;
  }
  return true;
}

void CookiesGetAllFunction::GetAllCookiesCallback(const net::CookieList& cookie_list) {
  base::ListValue results;
  for (const net::CanonicalCookie& cookie : cookie_list) {
    if (MatchesFilter(cookie)) {
      results.Append(CreateCookieValue(cookie));
    }
  }
  Respond(WithArguments(std::move(results)));
}

void CookiesGetAllFunction::GetCookieListCallback(
    const net::CookieAccessResultList& cookie_list,
    const net::CookieAccessResultList& excluded_cookies) {
  base::ListValue results;
  for (const net::CookieWithAccessResult& entry : cookie_list) {
    if (MatchesFilter(entry.cookie)) {
      results.Append(CreateCookieValue(entry.cookie));
    }
  }
  Respond(WithArguments(std::move(results)));
}

ExtensionFunction::ResponseAction CookiesSetFunction::Run() {
  const base::DictValue* details = args().empty() ? nullptr : args()[0].GetIfDict();
  EXTENSION_FUNCTION_VALIDATE(details);

  const std::string* url_string = details->FindString("url");
  EXTENSION_FUNCTION_VALIDATE(url_string);

  std::string error;
  if (!ParseUrl(extension(), *url_string, &url_, /*check_host_permissions=*/true,
               &error)) {
    return RespondNow(Error(std::move(error)));
  }

  const std::string* store_id = details->FindString("storeId");
  if (!CheckStoreId(store_id ? *store_id : std::string(), &error)) {
    return RespondNow(Error(std::move(error)));
  }

  network::mojom::CookieManager* cookie_manager = CookieManagerFor(browser_context());
  if (!cookie_manager) {
    return RespondNow(Error(kNoCookieStoreError));
  }

  const std::string* name = details->FindString("name");
  const std::string* value = details->FindString("value");
  const std::string* domain = details->FindString("domain");
  const std::string* path = details->FindString("path");
  name_ = name ? *name : std::string();

  base::Time expiration_time;
  if (std::optional<double> expiration_date = details->FindDouble("expirationDate")) {
    expiration_time = *expiration_date == 0
                          ? base::Time::UnixEpoch()
                          : base::Time::FromSecondsSinceUnixEpoch(*expiration_date);
  }

  std::unique_ptr<net::CanonicalCookie> cookie = net::CanonicalCookie::CreateSanitizedCookie(
      url_, name_, value ? *value : std::string(), domain ? *domain : std::string(),
      path ? *path : std::string(),
      /*creation_time=*/base::Time(), expiration_time,
      /*last_access_time=*/base::Time(),
      details->FindBool("secure").value_or(false),
      details->FindBool("httpOnly").value_or(false),
      SameSiteFromString(details->FindString("sameSite")),
      net::COOKIE_PRIORITY_DEFAULT, /*partition_key=*/std::nullopt,
      /*status=*/nullptr);
  if (!cookie) {
    success_ = false;
    state_ = kSetCompleted;
    GetCookieListCallback(net::CookieAccessResultList(), net::CookieAccessResultList());
    return AlreadyResponded();
  }

  net::CookieOptions options;
  options.set_include_httponly();
  options.set_same_site_cookie_context(
      net::CookieOptions::SameSiteCookieContext::MakeInclusive());

  // Setter immediately followed by getter: FIFO ordering on the CookieManager
  // pipe means no other write can land between them. Mirrors upstream CookiesSetFunction::Run().
  cookie_manager->SetCanonicalCookie(
      *cookie, url_, options,
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
          base::BindOnce(&CookiesSetFunction::SetCanonicalCookieCallback, this),
          net::CookieAccessResult()));
  cookie_manager->GetCookieList(
      url_, net::CookieOptions::MakeAllInclusive(), net::CookiePartitionKeyCollection(),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
          base::BindOnce(&CookiesSetFunction::GetCookieListCallback, this),
          net::CookieAccessResultList(), net::CookieAccessResultList()));
  return RespondLater();
}

void CookiesSetFunction::SetCanonicalCookieCallback(
    net::CookieAccessResult set_cookie_result) {
  DCHECK_EQ(kNoResponse, state_);
  state_ = kSetCompleted;
  success_ = set_cookie_result.status.IsInclude();
}

void CookiesSetFunction::GetCookieListCallback(
    const net::CookieAccessResultList& cookie_list,
    const net::CookieAccessResultList& excluded_cookies) {
  DCHECK_EQ(kSetCompleted, state_);
  state_ = kGetCompleted;

  if (!success_) {
    Respond(Error(
        extensions::ErrorUtils::FormatErrorMessage(kCookieSetFailedError, name_)));
    return;
  }

  for (const net::CookieWithAccessResult& entry : cookie_list) {
    if (entry.cookie.Name() == name_) {
      Respond(WithArguments(CreateCookieValue(entry.cookie)));
      return;
    }
  }
  Respond(NoArguments());
}

ExtensionFunction::ResponseAction CookiesRemoveFunction::Run() {
  const base::DictValue* details = args().empty() ? nullptr : args()[0].GetIfDict();
  EXTENSION_FUNCTION_VALIDATE(details);

  const std::string* url_string = details->FindString("url");
  const std::string* name = details->FindString("name");
  EXTENSION_FUNCTION_VALIDATE(url_string && name);
  name_ = *name;

  std::string error;
  if (!ParseUrl(extension(), *url_string, &url_, /*check_host_permissions=*/true,
               &error)) {
    return RespondNow(Error(std::move(error)));
  }

  const std::string* store_id = details->FindString("storeId");
  if (!CheckStoreId(store_id ? *store_id : std::string(), &error)) {
    return RespondNow(Error(std::move(error)));
  }

  network::mojom::CookieManager* cookie_manager = CookieManagerFor(browser_context());
  if (!cookie_manager) {
    return RespondNow(Error(kNoCookieStoreError));
  }

  auto filter = network::mojom::CookieDeletionFilter::New();
  filter->url = url_;
  filter->cookie_name = name_;
  cookie_manager->DeleteCookies(
      std::move(filter),
      mojo::WrapCallbackWithDefaultInvokeIfNotRun(
          base::BindOnce(&CookiesRemoveFunction::RemoveCookieCallback, this), 0u));
  return RespondLater();
}

void CookiesRemoveFunction::RemoveCookieCallback(uint32_t num_deleted) {
  base::DictValue details;
  details.Set("url", url_.spec());
  details.Set("name", name_);
  details.Set("storeId", kOnlyCookieStoreId);
  Respond(WithArguments(std::move(details)));
}

ExtensionFunction::ResponseAction CookiesGetAllCookieStoresFunction::Run() {
  base::ListValue tab_ids;
  for (const OrbitTabInfo* tab : OrbitTabRegistry::GetInstance().GetAllTabs()) {
    tab_ids.Append(tab->id);
  }

  base::DictValue store;
  store.Set("id", kOnlyCookieStoreId);
  store.Set("tabIds", std::move(tab_ids));

  base::ListValue stores;
  stores.Append(std::move(store));
  return RespondNow(WithArguments(std::move(stores)));
}

}  // namespace orbit
