#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
ROOT="$PWD"
STAGE="$ROOT/dist/openwrt"
mkdir -p "$STAGE"
# A fresh staging tree never receives bootstrap credentials or mutable runtime files.
rm -rf "$STAGE/root"
mkdir -p "$STAGE/root/usr/lib/yume-simhub/bin" "$STAGE/root/usr/lib/yume-simhub/tools/voice-runtime"
cp -R openwrt/root/. "$STAGE/root/"
cp version.json "$STAGE/root/usr/lib/yume-simhub/version.json"
cp Mac/supervisor.py "$STAGE/root/usr/lib/yume-simhub/"
for name in at_pty_bridge.py module_select.py usb_backend.py adb_server.py voice_runtime.py reset_route.py runtime_health.py runtime_lease.py owned_exec.py linux_audio_bridge.py; do
    cp "Mac/tools/$name" "$STAGE/root/usr/lib/yume-simhub/tools/"
done
# PyUSB is pure Python; bundle the pinned package rather than depending on pip
# being installed on an appliance. Exclude all host bytecode.
python3 - "$STAGE/root/usr/lib/yume-simhub/tools" <<'PYUSB'
import pathlib,shutil,sys
source=pathlib.Path('Mac/runtime-cache/python/lib/python3.12/site-packages')
if not (source/'usb/core.py').exists():raise SystemExit('Run scripts/prepare-runtime.py first to obtain pinned PyUSB')
shutil.copytree(source/'usb',pathlib.Path(sys.argv[1])/'usb',ignore=shutil.ignore_patterns('__pycache__','*.pyc'))
for license in source.glob('pyusb-*.dist-info/**/LICENSE*'):
    if license.is_file():shutil.copy2(license,pathlib.Path(sys.argv[1])/('PyUSB-'+license.name))
PYUSB
cp Mac/tools/LICENSE-dontmove-kit "$STAGE/root/usr/lib/yume-simhub/tools/"
# Verified, pinned module-side ARMv7 assets; never copy the host Python runtime.
PYTHONDONTWRITEBYTECODE=1 python3 - "$STAGE/root/usr/lib/yume-simhub/tools/voice-runtime" <<'PY'
import ast,hashlib,pathlib,sys,urllib.request
source=ast.parse(pathlib.Path('Mac/tools/voice_runtime.py').read_text())
values={}
for node in source.body:
    if isinstance(node,ast.Assign) and isinstance(node.targets[0],ast.Name):
        try: values[node.targets[0].id]=ast.literal_eval(node.value)
        except (ValueError,TypeError): pass
base='https://raw.githubusercontent.com/moluncn/mavo/'+values['UPSTREAM_COMMIT']+'/Resources/ModuleVoice/'
for item in values['RUNTIME_FILES']:
    cached=pathlib.Path('Mac/tools/voice-runtime')/item['name']
    data=cached.read_bytes() if cached.exists() else urllib.request.urlopen(base+item['name'],timeout=30).read(16*1024*1024)
    if hashlib.sha256(data).hexdigest()!=item['sha256']: raise SystemExit('Module asset checksum mismatch')
    target=pathlib.Path(sys.argv[1])/item['name'];target.write_bytes(data);target.chmod(item['mode'])
PY
(cd Mac/engine && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -ldflags '-s -w' -o "$STAGE/root/usr/lib/yume-simhub/bin/simhub-edge" ./cmd/simhub-edge)
cp openwrt/install.sh "$STAGE/install.sh"
(cd "$STAGE" && tar -czf ../yume-simhub-openwrt-arm64.tar.gz root install.sh)
(cd dist && shasum -a 256 yume-simhub-openwrt-arm64.tar.gz > yume-simhub-openwrt-arm64.sha256)
python3 openwrt/package.py
python3 - <<'PYHASH'
import hashlib,json,pathlib
v=json.loads(pathlib.Path('version.json').read_text())
p=pathlib.Path('dist')/f"luci-app-yume-simhub_{v['version']}-{v['build']}_aarch64_cortex-a53_neon-vfpv4.ipk"
with pathlib.Path('dist/yume-simhub-openwrt-arm64.sha256').open('a') as out:out.write(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+p.name+'\n')
PYHASH
echo "Built dist/yume-simhub-openwrt-arm64.tar.gz"
