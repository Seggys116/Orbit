// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_permission_message_provider.h"

#include <algorithm>
#include <iterator>
#include <map>
#include <set>
#include <string>
#include <string_view>

#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "extensions/common/extensions_client.h"
#include "extensions/common/permissions/api_permission.h"
#include "extensions/common/permissions/api_permission_set.h"
#include "extensions/common/permissions/manifest_permission.h"
#include "extensions/common/permissions/manifest_permission_set.h"
#include "extensions/common/permissions/permission_message_util.h"
#include "extensions/common/permissions/permission_set.h"
#include "extensions/common/url_pattern_set.h"

using extensions::APIPermission;
using extensions::APIPermissionSet;
using extensions::ManifestPermission;
using extensions::Manifest;
using extensions::PermissionID;
using extensions::PermissionIDSet;
using extensions::PermissionMessage;
using extensions::PermissionMessages;
using extensions::PermissionSet;
using extensions::mojom::APIPermissionID;

namespace orbit {

namespace {

// Ported 1:1 from ExtensionPermissionWarnings.swift's apiPermissionCatalog;
// must be kept in sync. Deliberately not exhaustive: an ID with no entry
// here (private/component-only API surface) simply contributes no bullet.
struct PermissionText {
  APIPermissionID id;
  const char* text;
};

constexpr PermissionText kPermissionMessages[] = {
    // Critical -- browser-wide or sandbox-escaping access.
    {APIPermissionID::kDebugger,
     "Access the Chrome DevTools debugger, which can read and change all "
     "your data on all websites"},
    {APIPermissionID::kNativeMessaging,
     "Communicate with cooperating native applications installed on your "
     "Mac"},

    // High -- meaningful personal data or page-level code execution.
    {APIPermissionID::kHistory, "Read and change your browsing history"},
    {APIPermissionID::kTab, "Read your browsing history"},
    {APIPermissionID::kBookmark, "Read and change your bookmarks"},
    {APIPermissionID::kCookie,
     "Read and change your cookies and other site data"},
    {APIPermissionID::kDownloads,
     "Manage your downloads: start, open, and remove downloaded files"},
    {APIPermissionID::kClipboardRead, "Read data you copy and paste"},
    {APIPermissionID::kClipboardWrite, "Modify data you copy and paste"},
    {APIPermissionID::kGeolocation, "Detect your physical location"},
    {APIPermissionID::kScripting,
     "Read and change all your data on the websites this extension can "
     "access"},
    {APIPermissionID::kDeclarativeNetRequest,
     "Block or modify network requests on websites you visit"},
    {APIPermissionID::kDeclarativeNetRequestWithHostAccess,
     "Block or modify network requests on websites you visit"},
    {APIPermissionID::kDeclarativeNetRequestFeedback,
     "Read details about network requests this extension has blocked or "
     "modified"},
    {APIPermissionID::kWebRequest,
     "Read and, in some cases, modify data you send and receive while "
     "browsing"},
    {APIPermissionID::kWebRequestBlocking,
     "Read and change data you send and receive while browsing, before it "
     "loads"},
    {APIPermissionID::kProxy, "Control your network traffic and proxy "
                             "settings"},
    {APIPermissionID::kBrowsingData,
     "Clear your browsing history, cookies, and other stored site data"},
    {APIPermissionID::kTabCapture,
     "Capture the visible contents of tabs you are viewing"},
    {APIPermissionID::kDesktopCapture,
     "Capture the contents of your screen, other windows, and other "
     "applications"},

    // Moderate -- real but narrower-blast-radius capabilities.
    {APIPermissionID::kActiveTab,
     "Access the page you're currently viewing, only when you click the "
     "extension's icon or use its menu"},
    {APIPermissionID::kManagement,
     "Manage your other extensions, apps, and themes"},
    {APIPermissionID::kPrivacy,
     "Change your privacy-related browser settings"},
    {APIPermissionID::kWebNavigation,
     "Know when you navigate to a new page and what that page's address is"},
    {APIPermissionID::kContentSettings,
     "Change settings that control which websites can use features like "
     "cookies, JavaScript, and plugins"},
    {APIPermissionID::kTopSites, "Read the list of pages you visit most "
                                "often"},
    {APIPermissionID::kSessions,
     "Read your browsing history on other devices signed in to Chrome"},
    {APIPermissionID::kFontSettings, "Change the fonts your browser uses"},
    {APIPermissionID::kPrinterProvider, "Interact with attached printers"},

    // Low -- narrow, local, or already-sandboxed capabilities.
    {APIPermissionID::kStorage, "Store data on your Mac"},
    {APIPermissionID::kUnlimitedStorage,
     "Store an unlimited amount of data on your Mac"},
    {APIPermissionID::kNotifications, "Display notifications"},
    {APIPermissionID::kContextMenus, "Add items to the right-click menu"},
    {APIPermissionID::kAlarms, "Schedule code to run at a later time"},
    {APIPermissionID::kIdle, "Detect when your Mac is idle"},
    {APIPermissionID::kPower,
     "Keep your Mac from sleeping while the extension is active"},
    {APIPermissionID::kIdentity,
     "Know your basic profile information from your signed-in account"},
    {APIPermissionID::kGcm, "Receive push messages sent to this extension"},
    {APIPermissionID::kSystemDisplay,
     "Read details about your connected displays"},
    {APIPermissionID::kSystemCpu, "Read details about your Mac's CPU"},
    {APIPermissionID::kSystemMemory,
     "Read details about your Mac's available memory"},
    {APIPermissionID::kSystemStorage,
     "Read details about your Mac's storage devices"},
    {APIPermissionID::kBackground,
     "Run in the background, even when no window is open"},
    {APIPermissionID::kOffscreen,
     "Create hidden pages to perform work off screen"},
    {APIPermissionID::kTts, "Read text out loud using text-to-speech"},
    {APIPermissionID::kFileSystemProvider,
     "Provide access to files as if they were on a local disk"},
};

const std::map<APIPermissionID, std::u16string>& MessageTable() {
  static const base::NoDestructor<std::map<APIPermissionID, std::u16string>>
      table([] {
        std::map<APIPermissionID, std::u16string> map;
        for (const auto& entry : kPermissionMessages) {
          map.emplace(entry.id, base::UTF8ToUTF16(entry.text));
        }
        return map;
      }());
  return *table;
}

}  // namespace

OrbitPermissionMessageProvider::OrbitPermissionMessageProvider() = default;
OrbitPermissionMessageProvider::~OrbitPermissionMessageProvider() = default;

PermissionMessages OrbitPermissionMessageProvider::GetPermissionMessages(
    const PermissionIDSet& permissions) const {
  PermissionMessages messages;

  // Host permissions are summarized into a single bullet, exactly mirroring
  // ExtensionPermissionWarnings.swift's hostWarning(): a named single host,
  // an "N websites" count, or (for kHostsAll) the all-hosts warning.
  if (permissions.ContainsID(APIPermissionID::kHostsAll) ||
      permissions.ContainsID(APIPermissionID::kHostsAllReadOnly)) {
    PermissionIDSet host_ids;
    if (permissions.ContainsID(APIPermissionID::kHostsAll)) {
      host_ids.InsertAll(
          permissions.GetAllPermissionsWithID(APIPermissionID::kHostsAll));
    }
    if (permissions.ContainsID(APIPermissionID::kHostsAllReadOnly)) {
      host_ids.InsertAll(permissions.GetAllPermissionsWithID(
          APIPermissionID::kHostsAllReadOnly));
    }
    messages.emplace_back(
        u"Read and change all your data on all websites", host_ids);
  } else {
    PermissionIDSet read_write_hosts =
        permissions.GetAllPermissionsWithID(APIPermissionID::kHostReadWrite);
    PermissionIDSet read_only_hosts =
        permissions.GetAllPermissionsWithID(APIPermissionID::kHostReadOnly);
    PermissionIDSet all_hosts = read_write_hosts;
    all_hosts.InsertAll(read_only_hosts);
    if (!all_hosts.empty()) {
      std::vector<std::u16string> host_names =
          all_hosts.GetAllPermissionParameters();
      std::sort(host_names.begin(), host_names.end());
      std::u16string text;
      if (host_names.size() == 1) {
        text = u"Read and change your data on " + host_names[0];
      } else {
        text = u"Read and change your data on " +
               base::NumberToString16(host_names.size()) + u" websites";
      }
      messages.emplace_back(text, all_hosts, host_names);
    }
  }

  // Everything else: one bullet per known API/manifest permission ID, in
  // table order, de-duplicated by final text so no two IDs produce identical bullets.
  const auto& table = MessageTable();
  std::set<std::u16string> seen_text;
  for (const auto& entry : kPermissionMessages) {
    if (!permissions.ContainsID(entry.id)) {
      continue;
    }
    const std::u16string& text = table.at(entry.id);
    if (!seen_text.insert(text).second) {
      continue;
    }
    messages.emplace_back(
        text, permissions.GetAllPermissionsWithID(entry.id));
  }

  return messages;
}

bool OrbitPermissionMessageProvider::IsPrivilegeIncrease(
    const PermissionSet& granted_permissions,
    const PermissionSet& requested_permissions,
    Manifest::Type extension_type) const {
  if (IsHostPrivilegeIncrease(granted_permissions, requested_permissions,
                              extension_type)) {
    return true;
  }
  if (IsAPIOrManifestPrivilegeIncrease(granted_permissions,
                                       requested_permissions)) {
    return true;
  }
  return false;
}

PermissionIDSet OrbitPermissionMessageProvider::GetAllPermissionIDs(
    const PermissionSet& permissions,
    Manifest::Type extension_type) const {
  PermissionIDSet permission_ids;
  AddAPIPermissions(permissions, &permission_ids);
  AddManifestPermissions(permissions, &permission_ids);
  AddHostPermissions(permissions, &permission_ids, extension_type);
  return permission_ids;
}

void OrbitPermissionMessageProvider::AddAPIPermissions(
    const PermissionSet& permissions,
    PermissionIDSet* permission_ids) const {
  for (const APIPermission* permission : permissions.apis()) {
    permission_ids->InsertAll(permission->GetPermissions());
  }
}

void OrbitPermissionMessageProvider::AddManifestPermissions(
    const PermissionSet& permissions,
    PermissionIDSet* permission_ids) const {
  for (const ManifestPermission* p : permissions.manifest_permissions()) {
    permission_ids->InsertAll(p->GetPermissions());
  }
}

void OrbitPermissionMessageProvider::AddHostPermissions(
    const PermissionSet& permissions,
    PermissionIDSet* permission_ids,
    Manifest::Type extension_type) const {
  // Platform apps always use isolated storage, so there's nothing to warn
  // about. See chrome_permission_message_provider.cc's identical carve-out
  // -- this must stay consistent with IsHostPrivilegeIncrease below.
  if (extension_type == Manifest::Type::kPlatformApp) {
    return;
  }

  if (permissions.ShouldWarnAllHosts()) {
    permission_ids->insert(APIPermissionID::kHostsAll);
    return;
  }

  extensions::URLPatternSet regular_hosts;
  extensions::ExtensionsClient::Get()->FilterHostPermissions(
      permissions.effective_hosts(), &regular_hosts, permission_ids);

  std::set<std::string> hosts = permission_message_util::GetDistinctHosts(
      regular_hosts, /*include_rcd=*/true, /*exclude_file_scheme=*/true);
  for (const auto& host : hosts) {
    permission_ids->insert(APIPermissionID::kHostReadWrite,
                           base::UTF8ToUTF16(host));
  }
}

bool OrbitPermissionMessageProvider::IsAPIOrManifestPrivilegeIncrease(
    const PermissionSet& granted_permissions,
    const PermissionSet& requested_permissions) const {
  PermissionIDSet granted_ids;
  AddAPIPermissions(granted_permissions, &granted_ids);
  AddManifestPermissions(granted_permissions, &granted_ids);
  if (granted_permissions.ShouldWarnAllHosts()) {
    granted_ids.insert(APIPermissionID::kHostsAll);
  }

  PermissionIDSet potential_total_ids = granted_ids;
  AddAPIPermissions(requested_permissions, &potential_total_ids);
  AddManifestPermissions(requested_permissions, &potential_total_ids);
  if (requested_permissions.ShouldWarnAllHosts()) {
    potential_total_ids.insert(APIPermissionID::kHostsAll);
  }

  if (granted_ids.Includes(potential_total_ids)) {
    return false;
  }

  // Not all ID differences produce a user-visible message (many IDs have no
  // entry in kPermissionMessages), so compare the actual message sets rather
  // than the raw ID sets -- matches chrome_permission_message_provider.cc.
  PermissionMessages granted_messages = GetPermissionMessages(granted_ids);
  PermissionMessages total_messages =
      GetPermissionMessages(potential_total_ids);

  std::vector<std::u16string> granted_text;
  for (const auto& m : granted_messages) {
    granted_text.push_back(m.message());
  }
  std::vector<std::u16string> total_text;
  for (const auto& m : total_messages) {
    total_text.push_back(m.message());
  }
  std::sort(granted_text.begin(), granted_text.end());
  std::sort(total_text.begin(), total_text.end());

  return !std::includes(total_text.begin(), total_text.end(),
                        granted_text.begin(), granted_text.end());
}

bool OrbitPermissionMessageProvider::IsHostPrivilegeIncrease(
    const PermissionSet& granted_permissions,
    const PermissionSet& requested_permissions,
    Manifest::Type extension_type) const {
  if (extension_type == Manifest::Type::kPlatformApp) {
    return false;
  }
  if (granted_permissions.HasEffectiveAccessToAllHosts()) {
    return false;
  }
  if (requested_permissions.HasEffectiveAccessToAllHosts()) {
    return true;
  }

  const extensions::URLPatternSet& granted_list =
      granted_permissions.effective_hosts();
  const extensions::URLPatternSet& requested_list =
      requested_permissions.effective_hosts();

  std::set<std::string> requested_hosts_set(
      permission_message_util::GetDistinctHosts(requested_list, false,
                                                 false));
  std::set<std::string> granted_hosts_set(
      permission_message_util::GetDistinctHosts(granted_list, false, false));

  std::set<std::string> requested_hosts_only;
  std::set_difference(
      requested_hosts_set.begin(), requested_hosts_set.end(),
      granted_hosts_set.begin(), granted_hosts_set.end(),
      std::inserter(requested_hosts_only, requested_hosts_only.begin()));

  // Matching a wildcard subdomain against an already-granted wildcard parent
  // (e.g. requesting foo.example.com after already having *.example.com)
  // must not count as an increase -- identical logic to Chrome's.
  for (const auto& requested : requested_hosts_only) {
    bool host_matched = false;
    for (const auto& granted : granted_hosts_set) {
      if (granted.size() > 2 && granted[0] == '*' && granted[1] == '.') {
        std::string_view stripped_granted =
            std::string_view(granted).substr(1);
        if (base::EndsWith(requested, stripped_granted) ||
            requested == stripped_granted.substr(1)) {
          host_matched = true;
          break;
        }
      }
    }
    if (!host_matched) {
      return true;
    }
  }
  return false;
}

}  // namespace orbit
