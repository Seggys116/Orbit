// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_cookie_bridge.h"

#include <memory>
#include <optional>
#include <utility>
#include <vector>

#include "base/functional/bind.h"
#include "base/functional/callback.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/memory/ref_counted.h"
#include "base/memory/scoped_refptr.h"
#include "base/time/time.h"
#include "base/values.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browser_thread.h"
#include "content/public/browser/storage_partition.h"
#include "net/cookies/canonical_cookie.h"
#include "net/cookies/cookie_access_result.h"
#include "net/cookies/cookie_constants.h"
#include "net/cookies/cookie_inclusion_status.h"
#include "net/cookies/cookie_options.h"
#include "net/cookies/cookie_partition_key_collection.h"
#include "services/network/public/mojom/cookie_manager.mojom.h"
#include "url/gurl.h"

namespace orbit {

namespace {

network::mojom::CookieManager* CookieManagerFor(
    content::BrowserContext* browser_context) {
  if (!browser_context) {
    return nullptr;
  }
  content::StoragePartition* partition =
      browser_context->GetDefaultStoragePartition();
  return partition ? partition->GetCookieManagerForBrowserProcess() : nullptr;
}

std::string SameSiteToJSON(net::CookieSameSite same_site) {
  switch (same_site) {
    case net::CookieSameSite::NO_RESTRICTION:
      return "none";
    case net::CookieSameSite::LAX_MODE:
      return "lax";
    case net::CookieSameSite::STRICT_MODE:
      return "strict";
    case net::CookieSameSite::UNSPECIFIED:
      return "unspecified";
  }
  return "unspecified";
}

net::CookieSameSite SameSiteFromJSON(const std::string& value) {
  if (value == "none") {
    return net::CookieSameSite::NO_RESTRICTION;
  }
  if (value == "lax") {
    return net::CookieSameSite::LAX_MODE;
  }
  if (value == "strict") {
    return net::CookieSameSite::STRICT_MODE;
  }
  return net::CookieSameSite::UNSPECIFIED;
}

std::string CanonicalCookiesToJSON(const net::CookieAccessResultList& cookies) {
  base::ListValue list;
  for (const net::CookieWithAccessResult& item : cookies) {
    const net::CanonicalCookie& cookie = item.cookie;
    base::DictValue dict;
    dict.Set("name", cookie.Name());
    dict.Set("value", cookie.Value());
    dict.Set("domain", cookie.Domain());
    dict.Set("path", cookie.Path());
    dict.Set("secure", cookie.SecureAttribute());
    dict.Set("httpOnly", cookie.IsHttpOnly());
    dict.Set("sameSite", SameSiteToJSON(cookie.SameSite()));
    if (cookie.IsPersistent()) {
      dict.Set("expiresAt", cookie.ExpiryDate().InSecondsFSinceUnixEpoch());
    } else {
      dict.Set("expiresAt", base::Value());
    }
    dict.Set("createdAt", cookie.CreationDate().InSecondsFSinceUnixEpoch());
    dict.Set("lastAccessedAt", cookie.LastAccessDate().InSecondsFSinceUnixEpoch());
    list.Append(std::move(dict));
  }
  std::string json;
  if (!base::JSONWriter::Write(list, &json)) {
    json = "[]";
  }
  return json;
}

void ReplyWithCookiesJSON(base::OnceCallback<void(std::string)> callback,
                          const net::CookieAccessResultList& cookies,
                          const net::CookieAccessResultList& excluded_cookies) {
  std::move(callback).Run(CanonicalCookiesToJSON(cookies));
}

void ReplyWithDeleteCount(base::OnceClosure callback, uint32_t num_deleted) {
  std::move(callback).Run();
}

// Shared by every in-flight SetCanonicalCookie call one SetCookiesJSON
// dispatched; the last one to complete reports the total back.
class SetCookiesState : public base::RefCounted<SetCookiesState> {
 public:
  SetCookiesState(int total, base::OnceCallback<void(int)> callback)
      : remaining_(total), callback_(std::move(callback)) {}

  void OnResult(net::CookieAccessResult result) {
    if (result.status.IsInclude()) {
      ++accepted_;
    }
    if (--remaining_ == 0) {
      std::move(callback_).Run(accepted_);
    }
  }

 private:
  friend class base::RefCounted<SetCookiesState>;
  ~SetCookiesState() = default;

  int remaining_;
  int accepted_ = 0;
  base::OnceCallback<void(int)> callback_;
};

}  // namespace

void GetCookiesJSON(content::BrowserContext* browser_context,
                    const std::string& url,
                    base::OnceCallback<void(std::string)> callback) {
  network::mojom::CookieManager* manager = CookieManagerFor(browser_context);
  if (!manager) {
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(std::move(callback), std::string("[]")));
    return;
  }
  manager->GetCookieList(GURL(url), net::CookieOptions::MakeAllInclusive(),
                         net::CookiePartitionKeyCollection(),
                         base::BindOnce(&ReplyWithCookiesJSON, std::move(callback)));
}

void DeleteCookiesForURL(content::BrowserContext* browser_context,
                         const std::string& url,
                         base::OnceClosure callback) {
  network::mojom::CookieManager* manager = CookieManagerFor(browser_context);
  if (!manager) {
    content::GetUIThreadTaskRunner({})->PostTask(FROM_HERE, std::move(callback));
    return;
  }
  auto filter = network::mojom::CookieDeletionFilter::New();
  filter->url = GURL(url);
  manager->DeleteCookies(std::move(filter),
                        base::BindOnce(&ReplyWithDeleteCount, std::move(callback)));
}

void SetCookiesJSON(content::BrowserContext* browser_context,
                    const std::string& cookies_json,
                    base::OnceCallback<void(int)> callback) {
  network::mojom::CookieManager* manager = CookieManagerFor(browser_context);
  std::optional<base::ListValue> parsed =
      base::JSONReader::ReadList(cookies_json, base::JSON_PARSE_RFC);

  std::vector<std::pair<net::CanonicalCookie, GURL>> to_set;
  if (manager && parsed) {
    for (const base::Value& entry : *parsed) {
      if (!entry.is_dict()) {
        continue;
      }
      const base::DictValue& dict = entry.GetDict();
      const std::string* name = dict.FindString("name");
      const std::string* value = dict.FindString("value");
      const std::string* domain = dict.FindString("domain");
      if (!name || !value || !domain || domain->empty()) {
        continue;
      }
      const std::string* path_field = dict.FindString("path");
      const std::string path = path_field && !path_field->empty() ? *path_field : "/";
      const bool secure = dict.FindBool("secure").value_or(false);
      const bool http_only = dict.FindBool("httpOnly").value_or(false);
      const std::string* same_site_field = dict.FindString("sameSite");
      const net::CookieSameSite same_site =
          SameSiteFromJSON(same_site_field ? *same_site_field : "unspecified");

      base::Time expiry;
      if (const base::Value* expires_at = dict.Find("expiresAt");
          expires_at && (expires_at->is_double() || expires_at->is_int())) {
        expiry = base::Time::FromSecondsSinceUnixEpoch(
            expires_at->is_double() ? expires_at->GetDouble()
                                    : expires_at->GetInt());
      }

      // Host, not the cookie's own (possibly leading-dot) domain: GURL
      // rejects a leading '.' as a host; CreateSanitizedCookie's own `domain`
      // argument below is what decides the cookie's actual stored scope.
      const std::string host =
          domain->front() == '.' ? domain->substr(1) : *domain;
      const GURL source_url((secure ? "https://" : "http://") + host + path);
      if (!source_url.is_valid()) {
        continue;
      }

      net::CookieInclusionStatus status;
      std::unique_ptr<net::CanonicalCookie> cookie =
          net::CanonicalCookie::CreateSanitizedCookie(
              source_url, *name, *value, *domain, path, base::Time::Now(),
              expiry, base::Time::Now(), secure, http_only, same_site,
              net::COOKIE_PRIORITY_DEFAULT, /*partition_key=*/std::nullopt, &status);
      if (!cookie || !status.IsInclude()) {
        continue;
      }
      to_set.emplace_back(std::move(*cookie), source_url);
    }
  }

  if (to_set.empty()) {
    content::GetUIThreadTaskRunner({})->PostTask(
        FROM_HERE, base::BindOnce(std::move(callback), 0));
    return;
  }

  auto state = base::MakeRefCounted<SetCookiesState>(static_cast<int>(to_set.size()),
                                                      std::move(callback));
  for (auto& [cookie, source_url] : to_set) {
    manager->SetCanonicalCookie(
        cookie, source_url, net::CookieOptions::MakeAllInclusive(),
        base::BindOnce(&SetCookiesState::OnResult, state));
  }
}

}  // namespace orbit
