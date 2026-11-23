#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
[ "$(uname -m)" = arm64 ] || { echo 'Apple Silicon is required'; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 26 ] || { echo 'macOS 26 or later is required'; exit 1; }
mkdir -p Mac/bin dist
python3.12 scripts/prepare-runtime.py
VERSION=$(python3 -c 'import json;print(json.load(open("version.json"))["version"])')
BUILD=$(python3 - <<'PYBUILD'
import json,plistlib,os
from pathlib import Path
base=int(json.loads(Path('version.json').read_text())['build'])
candidates=[
    Path.home()/'Applications/Yume SIMBridge.app',Path('/Applications/Yume SIMBridge.app'),
    Path.home()/'Applications/Yume SIM Hub.app',Path('/Applications/Yume SIM Hub.app')]
install_dest=os.environ.get('SIMBRIDGE_INSTALL_DEST') or os.environ.get('SIMHUB_INSTALL_DEST')
if install_dest:candidates.append(Path(install_dest))
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
APP="$ROOT/dist/Yume SIMBridge.app"
# This is a generated artifact. Rebuild the bundle from an empty staging folder.
if [ -d "$APP" ]; then rm -rf "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Mac/bin" "$APP/Contents/Resources/Mac/tools"
cp "$BIN/YumeSIMBridge" "$APP/Contents/MacOS/YumeSIMBridge"
cp MacApp/Translations.json "$APP/Contents/Resources/Translations.json"
python3 - "$ROOT" "$APP" <<'PYRUNTIME'
import shutil,sys
from pathlib import Path
root,app=map(Path,sys.argv[1:])
shutil.copytree(root/'Mac/runtime-cache/python',app/'Contents/Resources/Python',symlinks=False,
                ignore=shutil.ignore_patterns('__pycache__','*.pyc','*.pyo'))
PYRUNTIME
cp Mac/runtime-cache/libusb-1.0.0.dylib "$APP/Contents/Resources/Mac/bin/"
cp Mac/runtime-cache/libusb-LICENSE.txt "$APP/Contents/Resources/"
cp MacApp/AppIcon.icns "$APP/Contents/Resources/AppIcon-$BUILD.icns"
cp MacApp/SimHubLogo.png "$APP/Contents/Resources/SimHubLogo.png"
cp Mac/bin/simhub-edge Mac/bin/voice-audio-bridge "$APP/Contents/Resources/Mac/bin/"
cp Mac/supervisor.py "$APP/Contents/Resources/Mac/"
cp Mac/tools/owned_exec.py Mac/tools/runtime_lease.py Mac/tools/module_select.py Mac/tools/adb_server.py Mac/tools/runtime_health.py Mac/tools/at_pty_bridge.py Mac/tools/voice_runtime.py Mac/tools/reset_route.py Mac/tools/usb_backend.py Mac/tools/install_update.py Mac/tools/update_cleanup.py Mac/tools/LICENSE-dontmove-kit "$APP/Contents/Resources/Mac/tools/"
if [ -d Mac/tools/voice-runtime ]; then cp -R Mac/tools/voice-runtime "$APP/Contents/Resources/Mac/tools/"; fi
cp Mac/engine/LICENSE-CellBridge "$APP/Contents/Resources/"
python3 - "$ROOT" "$APP" "$BUILD" <<'PY'
import json,sys,plistlib
from pathlib import Path
root,app=map(Path,sys.argv[1:3])
effective_build=int(sys.argv[3])
with (app/'Contents/Resources/installation.json').open('w') as f:json.dump({'python':'Python/bin/python3.12','standalone':True},f)
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
    purpose={'en':'Reads DJI USB call audio to bridge phone calls.','fr':'Lit le son USB du module DJI pour relayer les appels.','ja':'DJI モジュールの USB 通話音声を読み取り、電話回線へ中継します。','zh-Hans':'读取 DJI 模块的 USB 通话音频，并桥接到电话网络。','zh-Hant':'讀取 DJI 模組的 USB 通話音訊，並橋接至電話網路。'}[language]
    (directory/'InfoPlist.strings').write_text('"NSMicrophoneUsageDescription" = '+json.dumps(purpose,ensure_ascii=False)+';\n')

with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump({'CFBundleExecutable':'YumeSIMBridge','CFBundleIdentifier':'zone.yume.simhub','CFBundleName':'Yume SIMBridge','CFBundleIconFile':f'AppIcon-{effective_build}','CFBundleDisplayName':'Yume SIMBridge','CFBundlePackageType':'APPL','CFBundleShortVersionString':version['version'],'CFBundleVersion':str(effective_build),'LSMinimumSystemVersion':'26.0','LSArchitecturePriority':['arm64'],'LSRequiresNativeExecution':True,'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','fr','ja','zh-Hans','zh-Hant'],'NSHighResolutionCapable':True,'NSMicrophoneUsageDescription':'用于读取 DJI 模块的 USB 通话音频，并桥接到电话网络。'},f)
PY
python3 scripts/sign-mac.py "$APP"
if [ "${1:-}" = "--install" ]; then
 mkdir -p "$HOME/Applications"
 destination="${SIMBRIDGE_INSTALL_DEST:-${SIMHUB_INSTALL_DEST:-}}"
 if [ -z "$destination" ]; then
  for candidate in "$HOME/Applications/Yume SIMBridge.app" "$HOME/Applications/Yume SIM Hub.app" \
                   "/Applications/Yume SIMBridge.app" "/Applications/Yume SIM Hub.app"; do
   if [ -d "$candidate" ]; then destination="$candidate"; break; fi
  done
 fi
 python3 scripts/install-app.py "$APP" "${destination:-$HOME/Applications/Yume SIMBridge.app}"
fi
printf 'Built: %s\n' "$APP"
