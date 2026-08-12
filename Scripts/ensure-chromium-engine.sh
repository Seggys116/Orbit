#!/bin/bash

set -euo pipefail

if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT="${SRCROOT}"
else
  REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi

CHROMIUM="${REPO_ROOT}/Scripts/chromium"

if [ ! -x "${CHROMIUM}" ]; then
  echo "error: ${CHROMIUM} is missing or not executable. This checkout is incomplete." >&2
  exit 1
fi

JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"
CONFIG="${ORBIT_ENGINE_CONFIG:-shipping}"

# Status is captured with `set +e` rather than `if ! ...`, where the shell has already inverted it and $? reads 0.
set +e
"${CHROMIUM}" ensure --jobs "${JOBS}" --config "${CONFIG}" --quiet
status=$?
set -e

if [ "${status}" -ne 0 ]; then
  echo "error: the Chromium engine (${CONFIG}) could not be installed, so this build cannot produce Orbit." >&2
  echo "note: Orbit embeds Chromium; there is no usable build without it, and no second" >&2
  echo "note: backend to build instead. See the output above." >&2
  exit "${status}"
fi
