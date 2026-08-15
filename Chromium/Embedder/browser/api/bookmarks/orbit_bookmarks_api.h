// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_API_BOOKMARKS_ORBIT_BOOKMARKS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_BOOKMARKS_ORBIT_BOOKMARKS_API_H_

#include "extensions/browser/extension_function.h"

namespace orbit {

class BookmarksGetFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.get", BOOKMARKS_GET)

 protected:
  ~BookmarksGetFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksGetChildrenFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.getChildren", BOOKMARKS_GETCHILDREN)

 protected:
  ~BookmarksGetChildrenFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksGetRecentFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.getRecent", BOOKMARKS_GETRECENT)

 protected:
  ~BookmarksGetRecentFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksGetTreeFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.getTree", BOOKMARKS_GETTREE)

 protected:
  ~BookmarksGetTreeFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksGetSubTreeFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.getSubTree", BOOKMARKS_GETSUBTREE)

 protected:
  ~BookmarksGetSubTreeFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksSearchFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.search", BOOKMARKS_SEARCH)

 protected:
  ~BookmarksSearchFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksCreateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.create", BOOKMARKS_CREATE)

 protected:
  ~BookmarksCreateFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksMoveFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.move", BOOKMARKS_MOVE)

 protected:
  ~BookmarksMoveFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksUpdateFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.update", BOOKMARKS_UPDATE)

 protected:
  ~BookmarksUpdateFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksRemoveFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.remove", BOOKMARKS_REMOVE)

 protected:
  ~BookmarksRemoveFunction() override = default;
  ResponseAction Run() override;
};

class BookmarksRemoveTreeFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("bookmarks.removeTree", BOOKMARKS_REMOVETREE)

 protected:
  ~BookmarksRemoveTreeFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_BOOKMARKS_ORBIT_BOOKMARKS_API_H_
