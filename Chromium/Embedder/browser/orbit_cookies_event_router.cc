// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_cookies_event_router.h"

#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/notreached.h"
#include "base/values.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/storage_partition.h"
#include "extensions/browser/event_router.h"
#include "extensions/browser/extension_event_histogram_value.h"
#include "extensions/common/extension.h"
#include "extensions/common/mojom/api_permission_id.mojom-shared.h"
#include "extensions/common/mojom/context_type.mojom-shared.h"
#include "extensions/common/mojom/event_dispatcher.mojom.h"
#include "extensions/common/permissions/permissions_data.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_change_dispatcher.h"
#include "net/cookies/cookie_util.h"
#include "url/gurl.h"

namespace orbit {

namespace {

using extensions::mojom::APIPermissionID;

constexpr char kCauseKey[] = "cause";
constexpr char kCookieKey[] = "cookie";
constexpr char kRemovedKey[] = "removed";

constexpr char kEvictedChangeCause[] = "evicted";
constexpr char kExpiredChangeCause[] = "expired";
constexpr char kExpiredOverwriteChangeCause[] = "expired_overwrite";
constexpr char kExplicitChangeCause[] = "explicit";
constexpr char kOverwriteChangeCause[] = "overwrite";

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

// Duplicates orbit_cookies_api.cc's own CreateCookieValue; kept local since
// the two files have no common header and it's not worth a third file.
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
    dict.Set("expirationDate", cookie.ExpiryDate().InSecondsFSinceUnixEpoch());
  }
  dict.Set("storeId", "0");
  return dict;
}

GURL URLFromCanonicalCookie(const net::CanonicalCookie& cookie) {
  return net::cookie_util::CookieOriginToURL(cookie.Domain(),
                                             cookie.SecureAttribute());
}

// Gates cookies.onChanged on both the "cookies" permission and host
// permission for the changed cookie's URL, mirroring upstream's per-listener
// checks since Orbit has no equivalent plumbing outside a WillDispatchCallback.
bool WillDispatchIfCookiePermitted(
    const GURL& cookie_url,
    content::BrowserContext* browser_context,
    extensions::mojom::ContextType context_type,
    const extensions::Extension* extension,
    const base::DictValue* listener_filter,
    std::optional<base::ListValue>& event_args_out,
    extensions::mojom::EventFilteringInfoPtr& event_filtering_info_out,
    bool* dispatch_separate_event_out) {
  return extension &&
        extension->permissions_data()->HasAPIPermission(APIPermissionID::kCookie) &&
        extension->permissions_data()->HasHostPermission(cookie_url);
}

}  // namespace

// static
OrbitCookiesEventRouter& OrbitCookiesEventRouter::GetInstance() {
  static base::NoDestructor<OrbitCookiesEventRouter> instance;
  return *instance;
}

OrbitCookiesEventRouter::OrbitCookiesEventRouter() = default;
OrbitCookiesEventRouter::~OrbitCookiesEventRouter() = default;

void OrbitCookiesEventRouter::StartObserving(content::BrowserContext* browser_context) {
  if (!browser_context || receiver_.is_bound()) {
    return;
  }
  browser_context_ = browser_context;
  BindToCookieManager();
}

void OrbitCookiesEventRouter::StopObserving() {
  receiver_.reset();
  browser_context_ = nullptr;
}

void OrbitCookiesEventRouter::BindToCookieManager() {
  if (!browser_context_) {
    return;
  }
  content::StoragePartition* partition = browser_context_->GetDefaultStoragePartition();
  network::mojom::CookieManager* cookie_manager =
      partition ? partition->GetCookieManagerForBrowserProcess() : nullptr;
  if (!cookie_manager) {
    return;
  }
  cookie_manager->AddGlobalChangeListener(receiver_.BindNewPipeAndPassRemote());
  receiver_.set_disconnect_handler(base::BindOnce(
      &OrbitCookiesEventRouter::OnConnectionError, base::Unretained(this)));
}

void OrbitCookiesEventRouter::OnConnectionError() {
  receiver_.reset();
  BindToCookieManager();
}

void OrbitCookiesEventRouter::OnCookieChange(const net::CookieChangeInfo& change) {
  if (!browser_context_) {
    return;
  }
  extensions::EventRouter* router = extensions::EventRouter::Get(browser_context_);
  if (!router) {
    return;
  }

  base::DictValue dict;
  dict.Set(kRemovedKey,
          change.cause != net::CookieChangeCause::INSERTED &&
              change.cause != net::CookieChangeCause::INSERTED_NO_CHANGE_OVERWRITE &&
              change.cause != net::CookieChangeCause::INSERTED_NO_VALUE_CHANGE_OVERWRITE);
  dict.Set(kCookieKey, CreateCookieValue(change.cookie));

  std::string cause;
  switch (change.cause) {
    case net::CookieChangeCause::INSERTED:
    case net::CookieChangeCause::EXPLICIT:
    case net::CookieChangeCause::INSERTED_NO_CHANGE_OVERWRITE:
    case net::CookieChangeCause::INSERTED_NO_VALUE_CHANGE_OVERWRITE:
      cause = kExplicitChangeCause;
      break;
    case net::CookieChangeCause::OVERWRITE:
      cause = kOverwriteChangeCause;
      break;
    case net::CookieChangeCause::EXPIRED:
      cause = kExpiredChangeCause;
      break;
    case net::CookieChangeCause::EVICTED:
      cause = kEvictedChangeCause;
      break;
    case net::CookieChangeCause::EXPIRED_OVERWRITE:
      cause = kExpiredOverwriteChangeCause;
      break;
    case net::CookieChangeCause::UNKNOWN_DELETION:
      NOTREACHED();
  }
  dict.Set(kCauseKey, cause);

  base::ListValue args;
  args.Append(std::move(dict));

  const GURL cookie_url = URLFromCanonicalCookie(change.cookie);
  auto event = std::make_unique<extensions::Event>(
      extensions::events::COOKIES_ON_CHANGED, "cookies.onChanged", std::move(args));
  auto filter_info = extensions::mojom::EventFilteringInfo::New();
  filter_info->url = cookie_url;
  event->filter_info = std::move(filter_info);
  event->will_dispatch_callback =
      base::BindRepeating(&WillDispatchIfCookiePermitted, cookie_url);
  router->BroadcastEvent(std::move(event));
}

}  // namespace orbit
