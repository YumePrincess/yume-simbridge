#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
mkdir -p local/bin dist
VERSION=$(python3 -c 'import json;print(json.load(open("version.json"))["version"])')
BUILD=$(python3 -c 'import json;print(json.load(open("version.json"))["build"])')
(cd local/engine && go build -trimpath -ldflags "-X main.Version=$VERSION -X main.Build=$BUILD" -o ../bin/simhub-edge ./cmd/simhub-edge)
swiftc -O local/tools/voice_audio_bridge.swift -o local/bin/voice-audio-bridge
swift build -c release --package-path MacApp
BIN=$(swift build -c release --package-path MacApp --show-bin-path)
APP="$ROOT/dist/Yume SIM Hub.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/local/bin" "$APP/Contents/Resources/local/tools"
cp "$BIN/YumeSimHub" "$APP/Contents/MacOS/YumeSimHub"
cp MacApp/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp local/bin/simhub-edge local/bin/voice-audio-bridge "$APP/Contents/Resources/local/bin/"
cp local/supervisor.py "$APP/Contents/Resources/local/"
cp local/tools/at_pty_bridge.py local/tools/voice_runtime.py local/tools/reset_route.py local/tools/LICENSE-dontmove-kit "$APP/Contents/Resources/local/tools/"
if [ -d local/tools/voice-runtime ]; then cp -R local/tools/voice-runtime "$APP/Contents/Resources/local/tools/"; fi
cp local/engine/LICENSE-CellBridge "$APP/Contents/Resources/"
python3 - "$ROOT" "$APP" <<'PY'
import json,sys,plistlib
from pathlib import Path
root,app=map(Path,sys.argv[1:])
with (app/'Contents/Resources/installation.json').open('w') as f:json.dump({'python':str(root/'.venv/bin/python'),'bootstrap':str(root/'.secrets/edge.json'),'sourceRoot':str(root)},f)
version=json.loads((root/'version.json').read_text())
with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump({'CFBundleExecutable':'YumeSimHub','CFBundleIdentifier':'zone.yume.simhub','CFBundleName':'Yume SIM Hub','CFBundleIconFile':'AppIcon','CFBundleDisplayName':'Yume SIM Hub','CFBundlePackageType':'APPL','CFBundleShortVersionString':version['version'],'CFBundleVersion':str(version['build']),'LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'用于读取 DJI 模块的 USB 通话音频，并桥接到电话网络。'},f)
PY
codesign --force --deep --sign - "$APP"
if [ "${1:-}" = "--install" ]; then
 mkdir -p "$HOME/Applications"
 ditto "$APP" "$HOME/Applications/Yume SIM Hub.app"
fi
printf 'Built: %s\n' "$APP"
