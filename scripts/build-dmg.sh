#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
APP_ROOT=${SCRIPT_DIR:h}
DIST_ROOT="${SIMHUB_DIST_ROOT:-${APP_ROOT}/dist}"
APP_NAME="Yume SIM Hub.app"
APP_BUNDLE="${DIST_ROOT}/${APP_NAME}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_BUNDLE}/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_BUNDLE}/Contents/Info.plist")"
RELEASE_LABEL="Yume SIM Hub ${VERSION} Build ${BUILD}"
VOLUME_NAME="${RELEASE_LABEL} Installer"
WORK_ROOT="$(mktemp -d /private/tmp/simhub-dmg.XXXXXX)"
STAGING="${WORK_ROOT}/root"
RW_IMAGE="${WORK_ROOT}/writable.dmg"
MOUNT_POINT="${WORK_ROOT}/mounted"
DEVICE=""
FINAL_IMAGE="${DIST_ROOT}/${RELEASE_LABEL}.dmg"
PYTHON_BIN="${SIMHUB_DMG_PYTHON:-$(command -v python3 || true)}"

[[ -d "${APP_BUNDLE}" ]] || { echo "Build the App first: ./scripts/build-mac.sh" >&2; exit 1; }
[[ -x "${PYTHON_BIN}" ]] || { echo "Set SIMHUB_DMG_PYTHON to a Python environment with scripts/requirements-dmg.txt installed." >&2; exit 1; }
"${PYTHON_BIN}" -c 'import PIL, ds_store, mac_alias' || {
  echo "Install DMG build dependencies: python3 -m pip install -r ${SCRIPT_DIR}/requirements-dmg.txt" >&2
  exit 1
}

cleanup() {
  if [[ -n "${DEVICE}" ]]; then
    hdiutil detach -quiet "${DEVICE}" || true
  fi
  rm -rf -- "${WORK_ROOT}"
}
trap cleanup EXIT

mkdir -p "${STAGING}/.background"
mkdir -p "${MOUNT_POINT}"
ditto "${APP_BUNDLE}" "${STAGING}/${APP_NAME}"
# Distribution manifests contain no host paths or private bootstrap locations.
"${PYTHON_BIN}" - "${STAGING}/${APP_NAME}" <<'PYMANIFEST'
import json,sys
from pathlib import Path
p=Path(sys.argv[1])/'Contents/Resources/installation.json'
p.write_text(json.dumps({'python':'Python/bin/python3.12','standalone':True}))
PYMANIFEST
"${PYTHON_BIN}" "${SCRIPT_DIR}/sign-mac.py" "${STAGING}/${APP_NAME}"
codesign --verify --deep --strict "${STAGING}/${APP_NAME}"
ln -s /Applications "${STAGING}/Applications"
"${PYTHON_BIN}" "${SCRIPT_DIR}/build-dmg-background.py" "${STAGING}/.background/background.tiff"

hdiutil create -quiet -srcfolder "${STAGING}" -volname "${VOLUME_NAME}" -fs HFS+ -format UDRW "${RW_IMAGE}"
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen -mountpoint "${MOUNT_POINT}" "${RW_IMAGE}")
DEVICE=$(echo "${ATTACH_OUTPUT}" | awk '/Apple_HFS/ {print $1; exit}')
[[ -n "${DEVICE}" ]] || { echo "Could not determine the writable DMG device." >&2; exit 1; }
# Write metadata on the mounted volume so the background alias records its
# final HFS identity. No Finder automation, window resize, or timing waits.
"${PYTHON_BIN}" "${SCRIPT_DIR}/build-dmg-layout.py" "${MOUNT_POINT}" "${APP_NAME}"

sync
hdiutil detach -quiet "${DEVICE}"
DEVICE=""
hdiutil convert -quiet "${RW_IMAGE}" -format UDZO -imagekey zlib-level=9 -o "${WORK_ROOT}/final.dmg"
codesign --force --sign "${SIMHUB_CODESIGN_IDENTITY:--}" "${WORK_ROOT}/final.dmg"
FINAL_STAGING="$(mktemp "${DIST_ROOT}/.simhub-dmg.XXXXXX")"
cp -X "${WORK_ROOT}/final.dmg" "${FINAL_STAGING}"
mv -f -- "${FINAL_STAGING}" "${FINAL_IMAGE}"

ZIP_IMAGE="${DIST_ROOT}/${RELEASE_LABEL}.zip"
/usr/bin/ditto -c -k --norsrc --keepParent "${APP_BUNDLE}" "${WORK_ROOT}/update.zip"
ZIP_STAGING="$(mktemp "${DIST_ROOT}/.simhub-update.XXXXXX")"
cp -X "${WORK_ROOT}/update.zip" "${ZIP_STAGING}"
mv -f "${ZIP_STAGING}" "${ZIP_IMAGE}"
echo "Built ${FINAL_IMAGE}"
echo "Built ${ZIP_IMAGE}"

(cd "${DIST_ROOT}" && shasum -a 256 "${RELEASE_LABEL}.dmg" "${RELEASE_LABEL}.zip" > SHA256SUMS.txt)
