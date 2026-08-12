// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome.action ported to an embedder with no Browser/TabStripModel/ToolbarActionsModel;
// tab ids resolve via OrbitTabRegistry, mutations relay via OrbitExtensionActionDispatcher. No browserAction/pageAction aliases, openPopup or getUserSettings (absent from action.json too).

#ifndef ORBIT_EMBEDDER_BROWSER_API_ACTION_ORBIT_ACTION_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_ACTION_ORBIT_ACTION_API_H_

#include "base/memory/raw_ptr.h"
#include "base/values.h"
#include "extensions/browser/extension_function.h"

namespace extensions {
class ExtensionAction;
}  // namespace extensions

namespace gfx {
class Image;
}  // namespace gfx

namespace orbit {

// Resolves the calling extension's ExtensionAction and tab, then defers to
// RunExtensionAction; mirrors extensions::ExtensionActionFunction.
class ActionFunction : public ExtensionFunction {
 protected:
  ActionFunction();
  ~ActionFunction() override;

  ResponseAction Run() override;
  virtual ResponseAction RunExtensionAction() = 0;

  bool ExtractDataFromArguments();
  void NotifyChange();
  void SetVisible(bool visible);

  raw_ptr<const base::DictValue> details_ = nullptr;
  // ExtensionAction::kDefaultTabId unless the call named a tab.
  int tab_id_;
  raw_ptr<extensions::ExtensionAction> extension_action_ = nullptr;
};

class ActionSetIconFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.setIcon", ACTION_SETICON)

 protected:
  ~ActionSetIconFunction() override = default;
  ResponseAction RunExtensionAction() override;

 private:
  void OnIconLoaded(const gfx::Image& image);
};

class ActionSetTitleFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.setTitle", ACTION_SETTITLE)

 protected:
  ~ActionSetTitleFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionGetTitleFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.getTitle", ACTION_GETTITLE)

 protected:
  ~ActionGetTitleFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionSetPopupFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.setPopup", ACTION_SETPOPUP)

 protected:
  ~ActionSetPopupFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionGetPopupFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.getPopup", ACTION_GETPOPUP)

 protected:
  ~ActionGetPopupFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionSetBadgeTextFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.setBadgeText", ACTION_SETBADGETEXT)

 protected:
  ~ActionSetBadgeTextFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionGetBadgeTextFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.getBadgeText", ACTION_GETBADGETEXT)

 protected:
  ~ActionGetBadgeTextFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionSetBadgeBackgroundColorFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.setBadgeBackgroundColor",
                             ACTION_SETBADGEBACKGROUNDCOLOR)

 protected:
  ~ActionSetBadgeBackgroundColorFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionGetBadgeBackgroundColorFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.getBadgeBackgroundColor",
                             ACTION_GETBADGEBACKGROUNDCOLOR)

 protected:
  ~ActionGetBadgeBackgroundColorFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionSetBadgeTextColorFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.setBadgeTextColor",
                             ACTION_SETBADGETEXTCOLOR)

 protected:
  ~ActionSetBadgeTextColorFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionGetBadgeTextColorFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.getBadgeTextColor",
                             ACTION_GETBADGETEXTCOLOR)

 protected:
  ~ActionGetBadgeTextColorFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionEnableFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.enable", ACTION_ENABLE)

 protected:
  ~ActionEnableFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionDisableFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.disable", ACTION_DISABLE)

 protected:
  ~ActionDisableFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

class ActionIsEnabledFunction : public ActionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("action.isEnabled", ACTION_ISENABLED)

 protected:
  ~ActionIsEnabledFunction() override = default;
  ResponseAction RunExtensionAction() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_ACTION_ORBIT_ACTION_API_H_
