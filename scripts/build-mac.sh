#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
[ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required'; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo 'macOS 26 or later is required'; exit 1; }
mkdir -p Mac/bin dist
VERSION=$(python3 -c 'import json;print(json.load(open("version.json"))["version"])')
BUILD=$(python3 - <<'PYBUILD'
import json,plistlib,os
from pathlib import Path
base=int(json.loads(Path('version.json').read_text())['build'])
candidates=[Path.home()/'Applications/Yume SIM Hub.app',Path('/Applications/Yume SIM Hub.app')]
if os.environ.get('SIMHUB_INSTALL_DEST'):candidates.append(Path(os.environ['SIMHUB_INSTALL_DEST']))
previous=0
for candidate in candidates:
    installed=candidate/'Contents/Info.plist'
    if installed.exists():
        with installed.open('rb') as f:previous=max(previous,int(plistlib.load(f).get('CFBundleVersion','0')))
print(max(base,previous+1))
PYBUILD
)
(cd Mac/engine && env GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-X main.Version=$VERSION -X main.Build=$BUILD" -o ../bin/simhub-edge ./cmd/simhub-edge)
swiftc -target arm64-apple-macos26.0 -O Mac/tools/voice_audio_bridge.swift -o Mac/bin/voice-audio-bridge
swift build --arch arm64 -c release --package-path MacApp
BIN=$(swift build --arch arm64 -c release --package-path MacApp --show-bin-path)
APP="$ROOT/dist/Yume SIM Hub.app"
# This is a generated artifact. Rebuild the bundle from an empty staging folder.
if [ -d "$APP" ]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Mac/bin" "$APP/Contents/Resources/Mac/tools"
cp "$BIN/YumeSimHub" "$APP/Contents/MacOS/YumeSimHub"
cp MacApp/Translations.json "$APP/Contents/Resources/Translations.json"
cp scripts/bootstrap-mac.sh "$APP/Contents/Resources/bootstrap-mac.sh"
cp MacApp/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Mac/bin/simhub-edge Mac/bin/voice-audio-bridge "$APP/Contents/Resources/Mac/bin/"
cp Mac/supervisor.py "$APP/Contents/Resources/Mac/"
cp Mac/tools/at_pty_bridge.py Mac/tools/voice_runtime.py Mac/tools/reset_route.py Mac/tools/LICENSE-dontmove-kit "$APP/Contents/Resources/Mac/tools/"
if [ -d Mac/tools/voice-runtime ]; then cp -R Mac/tools/voice-runtime "$APP/Contents/Resources/Mac/tools/"; fi
cp Mac/engine/LICENSE-CellBridge "$APP/Contents/Resources/"
python3 - "$ROOT" "$APP" "$BUILD" <<'PY'
import json,sys,plistlib
from pathlib import Path
root,app=map(Path,sys.argv[1:3])
effective_build=int(sys.argv[3])
with (app/'Contents/Resources/installation.json').open('w') as f:json.dump({'python':str(root/'Mac/.venv/bin/python'),'bootstrap':str(root/'.secrets/edge.json'),'sourceRoot':str(root)},f)
version=json.loads((root/'version.json').read_text())
translations=json.loads((root/'MacApp/Translations.json').read_text())
for language in ['en','fr','ja','zh-Hans','zh-Hant']:
    directory=app/'Contents/Resources'/f'{language}.lproj'
    directory.mkdir(parents=True,exist_ok=True)
    rows=[]
    for key,values in translations.items():
        value=key if language=='zh-Hans' else values.get(language,key)
        rows.append(json.dumps(key,ensure_ascii=False)+' = '+json.dumps(value,ensure_ascii=False)+';')
    (directory/'Localizable.strings').write_text('\n'.join(rows)+'\n')

with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump({'CFBundleExecutable':'YumeSimHub','CFBundleIdentifier':'zone.yume.simhub','CFBundleName':'Yume SIM Hub','CFBundleIconFile':'AppIcon','CFBundleDisplayName':'Yume SIM Hub','CFBundlePackageType':'APPL','CFBundleShortVersionString':version['version'],'CFBundleVersion':str(effective_build),'LSMinimumSystemVersion':'26.0','LSArchitecturePriority':['arm64'],'LSRequiresNativeExecution':True,'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','fr','ja','zh-Hans','zh-Hant'],'NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'用于读取 DJI 模块的 USB 通话音频，并桥接到电话网络。'},f)
PY
codesign --force --deep --sign - "$APP"
if [ "${1:-}" = "--install" ]; then
 mkdir -p "$HOME/Applications"
 python3 scripts/install-app.py "$APP" "${SIMHUB_INSTALL_DEST:-$HOME/Applications/Yume SIM Hub.app}"
fi
printf 'Built: %s\n' "$APP"
