#!/bin/bash

set -euo pipefail

APP="${1:?usage: package-dmg.sh <Orbit.app> <output.dmg> [volume-name]}"
DMG="${2:?usage: package-dmg.sh <Orbit.app> <output.dmg> [volume-name]}"
VOLUME_NAME="${3:-Orbit}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

exec "${SCRIPT_DIR}/release" package \
  --app "${APP}" \
  --output "${DMG}" \
  --volume-name "${VOLUME_NAME}" \
  --no-sign
