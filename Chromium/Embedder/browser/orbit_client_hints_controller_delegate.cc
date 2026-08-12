// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_client_hints_controller_delegate.h"

#include <optional>
#include <string>
#include <utility>

#include "base/functional/bind.h"
#include "base/values.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "content/public/browser/network_service_instance.h"
#include "orbit/common/orbit_user_agent.h"
#include "services/network/public/cpp/is_potentially_trustworthy.h"
#include "services/network/public/mojom/web_client_hints_types.mojom-shared.h"
#include "third_party/blink/public/common/client_hints/enabled_client_hints.h"
#include "url/gurl.h"
#include "url/origin.h"

namespace orbit {

namespace {

constexpr char kAcceptCHPrefPath[] = "orbit.client_hints.accept_ch";

using WebClientHintsType = network::mojom::WebClientHintsType;

std::optional<WebClientHintsType> HintFromStoredValue(const base::Value& value) {
  const std::optional<int> raw = value.GetIfInt();
  if (!raw.has_value() || *raw < 0 ||
      *raw > static_cast<int>(WebClientHintsType::kMaxValue)) {
    return std::nullopt;
  }
  return static_cast<WebClientHintsType>(*raw);
}

}  // namespace

// static
void OrbitClientHintsControllerDelegate::RegisterProfilePrefs(
    PrefRegistrySimple* registry) {
  registry->RegisterDictionaryPref(kAcceptCHPrefPath);
}

OrbitClientHintsControllerDelegate::OrbitClientHintsControllerDelegate(
    PrefService* pref_service)
    : pref_service_(pref_service),
      network_quality_tracker_(
          base::BindRepeating(&content::GetNetworkService)) {}

OrbitClientHintsControllerDelegate::~OrbitClientHintsControllerDelegate() =
    default;

network::NetworkQualityTracker*
OrbitClientHintsControllerDelegate::GetNetworkQualityTracker() {
  return &network_quality_tracker_;
}

void OrbitClientHintsControllerDelegate::GetAllowedClientHintsFromSource(
    const url::Origin& origin,
    blink::EnabledClientHints* client_hints) {
  if (!client_hints) {
    return;
  }
  if (network::IsUrlPotentiallyTrustworthy(origin.GetURL())) {
    const base::DictValue& all = pref_service_->GetDict(kAcceptCHPrefPath);
    if (const base::ListValue* stored = all.FindList(origin.Serialize())) {
      for (const base::Value& value : *stored) {
        if (std::optional<WebClientHintsType> hint = HintFromStoredValue(value)) {
          client_hints->SetIsEnabled(*hint, true);
        }
      }
    }
  }
  for (WebClientHintsType hint : additional_hints_) {
    client_hints->SetIsEnabled(hint, true);
  }
}

// Orbit has no per-origin JavaScript switch; content's own caller separately
// consults the frame's WebPreferences.
bool OrbitClientHintsControllerDelegate::IsJavaScriptAllowed(
    const GURL& url,
    content::RenderFrameHost* parent_rfh) {
  return true;
}

blink::UserAgentMetadata
OrbitClientHintsControllerDelegate::GetUserAgentMetadata() {
  return orbit::GetUserAgentMetadata();
}

void OrbitClientHintsControllerDelegate::PersistClientHints(
    const url::Origin& primary_origin,
    content::RenderFrameHost* parent_rfh,
    const std::vector<WebClientHintsType>& client_hints) {
  const GURL url = primary_origin.GetURL();
  if (!url.is_valid() || !network::IsUrlPotentiallyTrustworthy(url)) {
    return;
  }
  if (!IsJavaScriptAllowed(url, parent_rfh)) {
    return;
  }

  ScopedDictPrefUpdate update(pref_service_, kAcceptCHPrefPath);
  const std::string origin_key = primary_origin.Serialize();
  if (client_hints.empty()) {
    update->Remove(origin_key);
    return;
  }

  base::ListValue stored;
  for (WebClientHintsType hint : client_hints) {
    stored.Append(static_cast<int>(hint));
  }
  update->Set(origin_key, std::move(stored));
}

void OrbitClientHintsControllerDelegate::SetAdditionalClientHints(
    const std::vector<WebClientHintsType>& hints) {
  additional_hints_ = hints;
}

void OrbitClientHintsControllerDelegate::ClearAdditionalClientHints() {
  additional_hints_.clear();
}

void OrbitClientHintsControllerDelegate::SetMostRecentMainFrameViewportSize(
    const gfx::Size& viewport_size) {
  viewport_size_ = viewport_size;
}

gfx::Size
OrbitClientHintsControllerDelegate::GetMostRecentMainFrameViewportSize() {
  return viewport_size_;
}

}  // namespace orbit
