#!/bin/bash

set -euo pipefail

APP="${1:?usage: sign-app.sh <Orbit.app> <signing-identity>}"
IDENTITY="${2:?usage: sign-app.sh <Orbit.app> <signing-identity>}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ARGS=(sign --app "${APP}" --identity "${IDENTITY}")
if [ -n "${ORBIT_SIGN_KEYCHAIN:-}" ]; then
  ARGS+=(--keychain "${ORBIT_SIGN_KEYCHAIN}")
fi

exec "${SCRIPT_DIR}/release" "${ARGS[@]}"
