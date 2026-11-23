#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain --untracked-files=normal)" ] || { echo 'Commit release sources first'; exit 1; }
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] || { echo 'Push main before publishing'; exit 1; }
SIMHUB_VERSION=$(python3 -c 'import json;print(json.load(open("version.json"))["version"])')
SIMHUB_BUILD=$(python3 -c 'import json;print(json.load(open("version.json"))["build"])')
SIMHUB_TAG="v${SIMHUB_VERSION}-build.${SIMHUB_BUILD}"
SIMHUB_DMG="dist/Yume SIMBridge ${SIMHUB_VERSION} Build ${SIMHUB_BUILD}.dmg"
[ -f "$SIMHUB_DMG" ] || { echo 'Build the matching DMG first'; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' 'dist/Yume SIMBridge.app/Contents/Info.plist')" = "$SIMHUB_BUILD" ] || { echo 'Synchronize release Build with the locally generated App before publishing'; exit 1; }
SIMHUB_IPK="dist/luci-app-yume-simbridge_${SIMHUB_VERSION}-${SIMHUB_BUILD}_aarch64_cortex-a53_neon-vfpv4.ipk"
[ -f "$SIMHUB_IPK" ] || { echo 'Build the matching OpenWrt package first'; exit 1; }
(cd dist && shasum -a 256 -c yume-simbridge-openwrt-arm64.sha256)

(cd dist && shasum -a 256 "$(basename "$SIMHUB_DMG")" > SHA256SUMS.txt && shasum -a 256 -c SHA256SUMS.txt)
if git rev-parse "$SIMHUB_TAG" >/dev/null 2>&1; then
 [ "$(git rev-list -1 "$SIMHUB_TAG")" = "$(git rev-parse HEAD)" ] || { echo 'Release tag points to another commit'; exit 1; }
else
 git tag "$SIMHUB_TAG"
fi
git push origin "$SIMHUB_TAG"
gh release create "$SIMHUB_TAG" "$SIMHUB_DMG" dist/SHA256SUMS.txt "$SIMHUB_IPK" dist/yume-simbridge-openwrt-arm64.tar.gz dist/yume-simbridge-openwrt-arm64.sha256 --repo YumePrincess/yume-simbridge --verify-tag --title "Yume SIMBridge ${SIMHUB_VERSION} Build ${SIMHUB_BUILD}" --notes-file MacApp/ReleaseNotes.md
