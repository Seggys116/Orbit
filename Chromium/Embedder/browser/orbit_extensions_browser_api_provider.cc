// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_extensions_browser_api_provider.h"

#include "extensions/browser/extension_function_registry.h"
#include "orbit/browser/api/action/orbit_action_api.h"
#include "orbit/browser/api/bookmarks/orbit_bookmarks_api.h"
#include "orbit/browser/api/commands/orbit_commands_api.h"
#include "orbit/browser/api/context_menus/orbit_context_menus_api.h"
#include "orbit/browser/api/cookies/orbit_cookies_api.h"
#include "orbit/browser/api/downloads/orbit_downloads_api.h"
#include "orbit/browser/api/history/orbit_history_api.h"
#include "orbit/browser/api/permissions/orbit_permissions_api.h"
#include "orbit/browser/api/preference/orbit_preference_api.h"
#include "orbit/browser/api/search/orbit_search_api.h"
#include "orbit/browser/api/sessions/orbit_sessions_api.h"
#include "orbit/browser/api/tabs/orbit_tabs_api.h"
#include "orbit/browser/api/web_navigation/orbit_web_navigation_api.h"
#include "orbit/browser/api/windows/orbit_windows_api.h"

namespace orbit {

OrbitExtensionsBrowserAPIProvider::OrbitExtensionsBrowserAPIProvider() = default;
OrbitExtensionsBrowserAPIProvider::~OrbitExtensionsBrowserAPIProvider() = default;

void OrbitExtensionsBrowserAPIProvider::RegisterExtensionFunctions(
    ExtensionFunctionRegistry* registry) {
  registry->RegisterFunction<TabsGetFunction>();
  registry->RegisterFunction<TabsGetCurrentFunction>();
  registry->RegisterFunction<TabsQueryFunction>();
  registry->RegisterFunction<TabsCreateFunction>();
  registry->RegisterFunction<TabsUpdateFunction>();
  registry->RegisterFunction<TabsRemoveFunction>();
  registry->RegisterFunction<TabsReloadFunction>();

  registry->RegisterFunction<CookiesGetFunction>();
  registry->RegisterFunction<CookiesGetAllFunction>();
  registry->RegisterFunction<CookiesSetFunction>();
  registry->RegisterFunction<CookiesRemoveFunction>();
  registry->RegisterFunction<CookiesGetAllCookieStoresFunction>();

  registry->RegisterFunction<PermissionsGetAllFunction>();
  registry->RegisterFunction<PermissionsContainsFunction>();
  registry->RegisterFunction<PermissionsRequestFunction>();
  registry->RegisterFunction<PermissionsRemoveFunction>();

  registry->RegisterFunction<GetPreferenceFunction>();
  registry->RegisterFunction<SetPreferenceFunction>();
  registry->RegisterFunction<ClearPreferenceFunction>();

  registry->RegisterFunction<WindowsGetFunction>();
  registry->RegisterFunction<WindowsGetCurrentFunction>();
  registry->RegisterFunction<WindowsGetLastFocusedFunction>();
  registry->RegisterFunction<WindowsGetAllFunction>();

  registry->RegisterFunction<WebNavigationGetFrameFunction>();
  registry->RegisterFunction<WebNavigationGetAllFramesFunction>();

  registry->RegisterFunction<ActionSetIconFunction>();
  registry->RegisterFunction<ActionSetTitleFunction>();
  registry->RegisterFunction<ActionGetTitleFunction>();
  registry->RegisterFunction<ActionSetPopupFunction>();
  registry->RegisterFunction<ActionGetPopupFunction>();
  registry->RegisterFunction<ActionSetBadgeTextFunction>();
  registry->RegisterFunction<ActionGetBadgeTextFunction>();
  registry->RegisterFunction<ActionSetBadgeBackgroundColorFunction>();
  registry->RegisterFunction<ActionGetBadgeBackgroundColorFunction>();
  registry->RegisterFunction<ActionSetBadgeTextColorFunction>();
  registry->RegisterFunction<ActionGetBadgeTextColorFunction>();
  registry->RegisterFunction<ActionEnableFunction>();
  registry->RegisterFunction<ActionDisableFunction>();
  registry->RegisterFunction<ActionIsEnabledFunction>();

  registry->RegisterFunction<CommandsGetAllFunction>();

  registry->RegisterFunction<ContextMenusCreateFunction>();
  registry->RegisterFunction<ContextMenusUpdateFunction>();
  registry->RegisterFunction<ContextMenusRemoveFunction>();
  registry->RegisterFunction<ContextMenusRemoveAllFunction>();

  registry->RegisterFunction<HistorySearchFunction>();
  registry->RegisterFunction<HistoryGetVisitsFunction>();
  registry->RegisterFunction<HistoryAddUrlFunction>();
  registry->RegisterFunction<HistoryDeleteUrlFunction>();
  registry->RegisterFunction<HistoryDeleteRangeFunction>();
  registry->RegisterFunction<HistoryDeleteAllFunction>();

  registry->RegisterFunction<SessionsGetRecentlyClosedFunction>();
  registry->RegisterFunction<SessionsRestoreFunction>();

  registry->RegisterFunction<SearchQueryFunction>();

  registry->RegisterFunction<BookmarksGetFunction>();
  registry->RegisterFunction<BookmarksGetChildrenFunction>();
  registry->RegisterFunction<BookmarksGetRecentFunction>();
  registry->RegisterFunction<BookmarksGetTreeFunction>();
  registry->RegisterFunction<BookmarksGetSubTreeFunction>();
  registry->RegisterFunction<BookmarksSearchFunction>();
  registry->RegisterFunction<BookmarksCreateFunction>();
  registry->RegisterFunction<BookmarksMoveFunction>();
  registry->RegisterFunction<BookmarksUpdateFunction>();
  registry->RegisterFunction<BookmarksRemoveFunction>();
  registry->RegisterFunction<BookmarksRemoveTreeFunction>();

  registry->RegisterFunction<DownloadsDownloadFunction>();
  registry->RegisterFunction<DownloadsSearchFunction>();
  registry->RegisterFunction<DownloadsPauseFunction>();
  registry->RegisterFunction<DownloadsResumeFunction>();
  registry->RegisterFunction<DownloadsCancelFunction>();
  registry->RegisterFunction<DownloadsOpenFunction>();
  registry->RegisterFunction<DownloadsShowFunction>();
  registry->RegisterFunction<DownloadsShowDefaultFolderFunction>();
  registry->RegisterFunction<DownloadsEraseFunction>();
  registry->RegisterFunction<DownloadsRemoveFileFunction>();
}

}  // namespace orbit
