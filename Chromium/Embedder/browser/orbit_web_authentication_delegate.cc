// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_web_authentication_delegate.h"

#include <string>
#include <utility>

#include "base/base64.h"
#include "base/containers/span.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/pref_service.h"
#include "components/user_prefs/user_prefs.h"
#include "content/public/browser/browser_context.h"

#if BUILDFLAG(IS_MAC)
#include "device/fido/mac/credential_metadata.h"
#endif  // BUILDFLAG(IS_MAC)

namespace orbit {

namespace {

#if BUILDFLAG(IS_MAC)
constexpr char kTouchIdMetadataSecretPref[] = "webauthn.touchid.metadata_secret";

// Must match the keychain-access-groups entitlement on the signed executable,
// or TouchIdContext::TouchIdAvailableImpl refuses the authenticator.
constexpr char kKeychainAccessGroup[] =
    "H2X57PJPJ6.com.zak-noble-clarke.Orbit.webauthn";

// Regenerating this orphans every previously created passkey, so it is
// persisted in the profile's Preferences file and only minted when absent.
std::string TouchIdMetadataSecret(PrefService* prefs) {
  std::string secret = prefs->GetString(kTouchIdMetadataSecretPref);
  if (secret.empty() || !base::Base64Decode(secret, &secret)) {
    secret = device::fido::mac::GenerateCredentialMetadataSecret();
    prefs->SetString(kTouchIdMetadataSecretPref,
                     base::Base64Encode(base::as_byte_span(secret)));
  }
  return secret;
}
#endif  // BUILDFLAG(IS_MAC)

}  // namespace

// static
void OrbitWebAuthenticationDelegate::RegisterProfilePrefs(
    PrefRegistrySimple* registry) {
#if BUILDFLAG(IS_MAC)
  registry->RegisterStringPref(kTouchIdMetadataSecretPref, std::string());
#endif  // BUILDFLAG(IS_MAC)
}

OrbitWebAuthenticationDelegate::OrbitWebAuthenticationDelegate() = default;

OrbitWebAuthenticationDelegate::~OrbitWebAuthenticationDelegate() = default;

bool OrbitWebAuthenticationDelegate::SupportsResidentKeys(
    content::RenderFrameHost* render_frame_host) {
  return true;
}

#if BUILDFLAG(IS_MAC)
std::optional<OrbitWebAuthenticationDelegate::TouchIdAuthenticatorConfig>
OrbitWebAuthenticationDelegate::GetTouchIdAuthenticatorConfig(
    content::BrowserContext* browser_context) {
  PrefService* prefs = user_prefs::UserPrefs::Get(browser_context);
  if (!prefs) {
    return std::nullopt;
  }
  return TouchIdAuthenticatorConfig{
      .keychain_access_group = kKeychainAccessGroup,
      .metadata_secret = TouchIdMetadataSecret(prefs)};
}
#endif  // BUILDFLAG(IS_MAC)

}  // namespace orbit
