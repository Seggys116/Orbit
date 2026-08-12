#!/bin/bash
#
# Xcode Run Script phase (Orbit/OrbitDemo): copies Orbit Framework.framework out of
# ThirdParty/prebuilt/$ORBIT_ENGINE_CONFIG and ad-hoc/dev re-signs it -- a no-op, not a
# failure, before the framework is built. Distributable signing is Scripts/release's job.

set -euo pipefail

if [ -n "${SRCROOT:-}" ]; then
  REPO_ROOT="${SRCROOT}"
else
  REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
fi

FRAMEWORK_NAME="Orbit Framework.framework"
CONFIG="${ORBIT_ENGINE_CONFIG:-shipping}"
SOURCE_ROOT="${REPO_ROOT}/ThirdParty/prebuilt/${CONFIG}"
SOURCE_FRAMEWORK="${SOURCE_ROOT}/${FRAMEWORK_NAME}"

if [ ! -d "${SOURCE_FRAMEWORK}" ]; then
  for other in "${REPO_ROOT}"/ThirdParty/prebuilt/*/"${FRAMEWORK_NAME}"; do
    if [ -d "${other}" ]; then
      echo "error: no '${CONFIG}' engine at ${SOURCE_ROOT}, but another configuration is installed." >&2
      echo "note: embedding it anyway would ship the wrong DCHECK setting. Run:" >&2
      echo "note:   Scripts/chromium ensure --config ${CONFIG}" >&2
      exit 1
    fi
  done
  echo "note: ${FRAMEWORK_NAME} not built yet (build_target is not 'orbit' or the source build hasn't finished) -- skipping embed." >&2
  exit 0
fi

: "${BUILT_PRODUCTS_DIR:?must run inside an Xcode build}"
: "${CONTENTS_FOLDER_PATH:?must run inside an Xcode build}"

DEST_FRAMEWORKS="${BUILT_PRODUCTS_DIR}/${CONTENTS_FOLDER_PATH}/Frameworks"
DEST_FRAMEWORK="${DEST_FRAMEWORKS}/${FRAMEWORK_NAME}"

mkdir -p "${DEST_FRAMEWORKS}"
rm -rf "${DEST_FRAMEWORK}"
ditto "${SOURCE_FRAMEWORK}" "${DEST_FRAMEWORK}"
echo "embed-chromium-framework: copied ${FRAMEWORK_NAME} into ${CONTENTS_FOLDER_PATH}/Frameworks"

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
if [ -z "${IDENTITY}" ]; then
  IDENTITY="-"
fi

VERSIONED_DIR="${DEST_FRAMEWORK}/Versions/Current"
ENTITLEMENTS_DIR="${REPO_ROOT}/Orbit/Resources"

# Hardened runtime's Library Validation rejects a dlopen() across two ad-hoc signatures
# (dyld: "different Team IDs"), which is how every helper reaches the framework -- so an
# ad-hoc build must skip --options runtime, same as Xcode does for the outer app.
CODESIGN_OPTIONS=(--options runtime)
if [ "${IDENTITY}" = "-" ]; then
  CODESIGN_OPTIONS=()
fi

sign_bundle() {
  local path="$1"
  local entitlements="$2"
  if [ -n "${entitlements}" ]; then
    codesign --force --sign "${IDENTITY}" ${CODESIGN_OPTIONS[@]+"${CODESIGN_OPTIONS[@]}"} \
      --entitlements "${entitlements}" "${path}"
  else
    codesign --force --sign "${IDENTITY}" ${CODESIGN_OPTIONS[@]+"${CODESIGN_OPTIONS[@]}"} "${path}"
  fi
}

# Inside-out: helpers (each with its own entitlements) are signed before the framework
# that nests them, matching the process-and-sandbox design note section 4.1.
if [ -d "${VERSIONED_DIR}/Helpers/Orbit Helper (Renderer).app" ]; then
  sign_bundle "${VERSIONED_DIR}/Helpers/Orbit Helper (Renderer).app" \
    "${ENTITLEMENTS_DIR}/OrbitHelper-Renderer.entitlements"
fi
if [ -d "${VERSIONED_DIR}/Helpers/Orbit Helper (GPU).app" ]; then
  sign_bundle "${VERSIONED_DIR}/Helpers/Orbit Helper (GPU).app" \
    "${ENTITLEMENTS_DIR}/OrbitHelper-GPU.entitlements"
fi
if [ -d "${VERSIONED_DIR}/Helpers/Orbit Helper.app" ]; then
  sign_bundle "${VERSIONED_DIR}/Helpers/Orbit Helper.app" ""
fi

sign_bundle "${DEST_FRAMEWORK}" ""

echo "embed-chromium-framework: signed framework + helpers with identity '${IDENTITY}'"
