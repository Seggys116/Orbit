#!/bin/bash

set -euo pipefail

FILE="${1:?usage: notarize.sh <submission-file> [staple-target]}"
STAPLE_TARGET="${2:-}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

ARGS=(notarize --file "${FILE}")
if [ -n "${STAPLE_TARGET}" ]; then
  ARGS+=(--staple "${STAPLE_TARGET}")
fi

exec "${SCRIPT_DIR}/release" "${ARGS[@]}"
