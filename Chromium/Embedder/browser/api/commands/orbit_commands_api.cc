// Copyright 2026 The Orbit Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "orbit_commands_api.h"

#include <utility>

#include "extensions/common/extension.h"
#include "orbit/browser/orbit_command_service.h"

namespace orbit {

ExtensionFunction::ResponseAction CommandsGetAllFunction::Run() {
  if (!extension()) {
    return RespondNow(Error("No extension."));
  }
  return RespondNow(WithArguments(
      OrbitCommandService::GetInstance().GetCommandsForExtension(*extension())));
}

}  // namespace orbit
