// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// Per-origin decisions persisted on OrbitBrowserContext's PrefService; deliberately no
// HostContentSettingsMap (chrome/-layer, not linked). One store, not a shadow copy.

#ifndef ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSION_STORE_H_
#define ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSION_STORE_H_

#include <optional>
#include <string_view>

#include "base/memory/raw_ptr.h"

class PrefService;
class PrefRegistrySimple;

namespace blink {
enum class PermissionType;
}  // namespace blink

namespace url {
class Origin;
}  // namespace url

namespace orbit {

class OrbitPermissionStore {
 public:
  // Mirrors Orbit/Engine/EngineTypes.swift's PermissionKind; every Swift-facing JSON
  // payload round-trips through KindFromString/KindToString using exactly these strings.
  enum class Kind {
    kCamera,
    kMicrophone,
    kGeolocation,
    kNotifications,
    kClipboardRead,
    kMidi,
    kScreenCapture,
    kProtectedMediaIdentifier,
    kSensors,
    kFileSystemWrite,
  };

  // Mirrors Orbit/Engine/EngineTypes.swift's ContentSetting; kAsk means "never
  // answered" and is never itself persisted -- Set(..., kAsk) clears any
  // stored entry instead of writing one.
  enum class Decision { kAsk, kAllow, kBlock };

  static void RegisterProfilePrefs(PrefRegistrySimple* registry);

  // std::nullopt for anything OrbitPermissionKind has no raw string for.
  static std::optional<Kind> KindFromString(std::string_view raw);
  static std::string_view KindToString(Kind kind);

  // std::nullopt for every blink::PermissionType this build cannot map to a
  // Swift-visible PermissionKind -- callers must treat that as "deny without
  // asking", never as "allow" (see OrbitPermissionControllerDelegate).
  static std::optional<Kind> KindForPermissionType(blink::PermissionType type);

  // pref_service must outlive this instance -- matches OrbitBrowserContext's
  // own pref_service_ member, which is what every real caller passes.
  explicit OrbitPermissionStore(PrefService* pref_service);
  OrbitPermissionStore(const OrbitPermissionStore&) = delete;
  OrbitPermissionStore& operator=(const OrbitPermissionStore&) = delete;
  ~OrbitPermissionStore();

  // kAsk for an origin that is not http/https -- there is nothing to key a
  // persisted decision on, and defaulting such an origin to granted would be
  // a real hole, not merely an unsupported case.
  Decision Get(Kind kind, const url::Origin& origin) const;

  // kAsk removes any stored entry for (kind, origin) rather than writing one;
  // a non-http(s) origin is silently ignored, matching Get's own refusal.
  void Set(Kind kind, const url::Origin& origin, Decision decision);

 private:
  const raw_ptr<PrefService> pref_service_;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_ORBIT_PERMISSION_STORE_H_
