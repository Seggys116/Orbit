// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef ORBIT_EMBEDDER_BROWSER_API_HISTORY_ORBIT_HISTORY_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_HISTORY_ORBIT_HISTORY_API_H_

#include <string>

#include "extensions/browser/extension_function.h"

namespace orbit {

class HistorySearchFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("history.search", HISTORY_SEARCH)

 protected:
  ~HistorySearchFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnSearchComplete(const std::string& json);
};

class HistoryGetVisitsFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("history.getVisits", HISTORY_GETVISITS)

 protected:
  ~HistoryGetVisitsFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnGetVisitsComplete(const std::string& json);
};

class HistoryAddUrlFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("history.addUrl", HISTORY_ADDURL)

 protected:
  ~HistoryAddUrlFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnAddUrlComplete(const std::string& json);
};

class HistoryDeleteUrlFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("history.deleteUrl", HISTORY_DELETEURL)

 protected:
  ~HistoryDeleteUrlFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnDeleteUrlComplete(const std::string& json);
};

class HistoryDeleteRangeFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("history.deleteRange", HISTORY_DELETERANGE)

 protected:
  ~HistoryDeleteRangeFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnDeleteRangeComplete(const std::string& json);
};

class HistoryDeleteAllFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("history.deleteAll", HISTORY_DELETEALL)

 protected:
  ~HistoryDeleteAllFunction() override = default;
  ResponseAction Run() override;

 private:
  void OnDeleteAllComplete(const std::string& json);
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_HISTORY_ORBIT_HISTORY_API_H_
