#!/bin/bash
set -euo pipefail
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SIMHUB_SOURCE="$1"
SIMHUB_MODE="${2:---check}"
[ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required'; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo 'macOS 26+ is required'; exit 1; }
xcode-select -p >/dev/null || { echo 'Please install Xcode Command Line Tools: xcode-select --install'; exit 1; }
if [ ! -d "$SIMHUB_SOURCE/.git" ]; then
 [ ! -e "$SIMHUB_SOURCE" ] || { echo 'Source folder exists without Git metadata; choose a clean folder.'; exit 1; }
 mkdir -p "$(dirname "$SIMHUB_SOURCE")"
 git clone --branch main --single-branch https://github.com/YumePrincess/yume-simhub.git "$SIMHUB_SOURCE"
fi
exec /bin/bash "$SIMHUB_SOURCE/scripts/install-mac.sh" "$SIMHUB_MODE"
