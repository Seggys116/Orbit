// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_permission_store.h"

#include "base/values.h"
#include "components/prefs/pref_registry_simple.h"
#include "components/prefs/pref_service.h"
#include "components/prefs/scoped_user_pref_update.h"
#include "third_party/blink/public/common/permissions/permission_utils.h"
#include "url/origin.h"

namespace orbit {

namespace {

constexpr char kPermissionsPrefPath[] = "orbit.content_settings.permissions";

constexpr char kAllowValue[] = "allow";
constexpr char kBlockValue[] = "block";

bool IsPersistableOrigin(const url::Origin& origin) {
  return !origin.opaque() && (origin.scheme() == "http" || origin.scheme() == "https");
}

}  // namespace

// static
void OrbitPermissionStore::RegisterProfilePrefs(PrefRegistrySimple* registry) {
  registry->RegisterDictionaryPref(kPermissionsPrefPath);
}

// static
std::optional<OrbitPermissionStore::Kind> OrbitPermissionStore::KindFromString(
    std::string_view raw) {
  if (raw == "camera") return Kind::kCamera;
  if (raw == "microphone") return Kind::kMicrophone;
  if (raw == "geolocation") return Kind::kGeolocation;
  if (raw == "notifications") return Kind::kNotifications;
  if (raw == "clipboardRead") return Kind::kClipboardRead;
  if (raw == "midi") return Kind::kMidi;
  if (raw == "screenCapture") return Kind::kScreenCapture;
  if (raw == "protectedMediaIdentifier") return Kind::kProtectedMediaIdentifier;
  if (raw == "sensors") return Kind::kSensors;
  if (raw == "fileSystemWrite") return Kind::kFileSystemWrite;
  return std::nullopt;
}

// static
std::string_view OrbitPermissionStore::KindToString(Kind kind) {
  switch (kind) {
    case Kind::kCamera: return "camera";
    case Kind::kMicrophone: return "microphone";
    case Kind::kGeolocation: return "geolocation";
    case Kind::kNotifications: return "notifications";
    case Kind::kClipboardRead: return "clipboardRead";
    case Kind::kMidi: return "midi";
    case Kind::kScreenCapture: return "screenCapture";
    case Kind::kProtectedMediaIdentifier: return "protectedMediaIdentifier";
    case Kind::kSensors: return "sensors";
    case Kind::kFileSystemWrite: return "fileSystemWrite";
  }
  return "";
}

// static
std::optional<OrbitPermissionStore::Kind>
OrbitPermissionStore::KindForPermissionType(blink::PermissionType type) {
  switch (type) {
    case blink::PermissionType::AUDIO_CAPTURE:
      return Kind::kMicrophone;
    case blink::PermissionType::VIDEO_CAPTURE:
      return Kind::kCamera;
    case blink::PermissionType::GEOLOCATION:
    case blink::PermissionType::GEOLOCATION_APPROXIMATE:
      return Kind::kGeolocation;
    case blink::PermissionType::NOTIFICATIONS:
      return Kind::kNotifications;
    case blink::PermissionType::CLIPBOARD_READ_WRITE:
      return Kind::kClipboardRead;
    case blink::PermissionType::MIDI:
    case blink::PermissionType::MIDI_SYSEX:
      return Kind::kMidi;
    case blink::PermissionType::DISPLAY_CAPTURE:
      return Kind::kScreenCapture;
    case blink::PermissionType::PROTECTED_MEDIA_IDENTIFIER:
      return Kind::kProtectedMediaIdentifier;
    case blink::PermissionType::SENSORS:
      return Kind::kSensors;
    default:
      // Includes CLIPBOARD_SANITIZED_WRITE (handled elsewhere as always-granted) and
      // every PermissionType with no Orbit UI surface -- deny outright, not silently grant.
      return std::nullopt;
  }
}

OrbitPermissionStore::OrbitPermissionStore(PrefService* pref_service)
    : pref_service_(pref_service) {}

OrbitPermissionStore::~OrbitPermissionStore() = default;

OrbitPermissionStore::Decision OrbitPermissionStore::Get(
    Kind kind, const url::Origin& origin) const {
  if (!IsPersistableOrigin(origin)) {
    return Decision::kAsk;
  }
  const base::DictValue& all = pref_service_->GetDict(kPermissionsPrefPath);
  const base::DictValue* for_origin = all.FindDict(origin.Serialize());
  if (!for_origin) {
    return Decision::kAsk;
  }
  const std::string* value = for_origin->FindString(KindToString(kind));
  if (!value) {
    return Decision::kAsk;
  }
  if (*value == kAllowValue) return Decision::kAllow;
  if (*value == kBlockValue) return Decision::kBlock;
  return Decision::kAsk;
}

void OrbitPermissionStore::Set(Kind kind, const url::Origin& origin, Decision decision) {
  if (!IsPersistableOrigin(origin)) {
    return;
  }
  ScopedDictPrefUpdate update(pref_service_, kPermissionsPrefPath);
  const std::string origin_key = origin.Serialize();
  const std::string_view kind_key = KindToString(kind);

  if (decision == Decision::kAsk) {
    if (base::DictValue* for_origin = update->FindDict(origin_key)) {
      for_origin->Remove(kind_key);
      if (for_origin->empty()) {
        update->Remove(origin_key);
      }
    }
    return;
  }

  update->EnsureDict(origin_key)
      ->Set(kind_key, decision == Decision::kAllow ? kAllowValue : kBlockValue);
}

}  // namespace orbit
