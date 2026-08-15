// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
//
// chrome/browser/extensions/api/commands/commands.{h,cc} against
// OrbitCommandService rather than chrome's CommandService. No user-assigned
// overrides exist in Orbit, so "shortcut" is the manifest's suggested key
// whenever that key is actually active.

#ifndef ORBIT_EMBEDDER_BROWSER_API_COMMANDS_ORBIT_COMMANDS_API_H_
#define ORBIT_EMBEDDER_BROWSER_API_COMMANDS_ORBIT_COMMANDS_API_H_

#include "extensions/browser/extension_function.h"

namespace orbit {

class CommandsGetAllFunction : public ExtensionFunction {
 public:
  DECLARE_EXTENSION_FUNCTION("commands.getAll", COMMANDS_GETALL)

 protected:
  ~CommandsGetAllFunction() override = default;
  ResponseAction Run() override;
};

}  // namespace orbit

#endif  // ORBIT_EMBEDDER_BROWSER_API_COMMANDS_ORBIT_COMMANDS_API_H_
