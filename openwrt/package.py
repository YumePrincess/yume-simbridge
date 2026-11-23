#!/usr/bin/env python3
"""Create an opkg IPK using the OpenWrt tar container format, without a host SDK."""
import io
import json
from pathlib import Path
import tarfile
import time

root=Path(__file__).resolve().parents[1]
version=json.loads((root/'version.json').read_text())
label=version['version']+'-'+str(version['build'])
stage=root/'dist/openwrt/root'
def tar_bytes(entries):
    out=io.BytesIO()
    with tarfile.open(fileobj=out,mode='w:gz',format=tarfile.GNU_FORMAT) as archive:
        for name,data,mode in entries:
            info=tarfile.TarInfo(name);info.size=len(data);info.mode=mode;info.mtime=int(time.time())
            archive.addfile(info,io.BytesIO(data))
    return out.getvalue()
control=f'''Package: luci-app-yume-simbridge
Version: {label}
Architecture: aarch64_cortex-a53_neon-vfpv4
Maintainer: Yume SIMBridge
Section: luci
Priority: optional
Depends: libc, luci-base, rpcd, python3-light, python3-codecs, python3-logging, python3-uuid, python3-urllib, python3-ctypes, python3-openssl, libusb-1.0-0, alsa-utils, kmod-usb-audio, ca-bundle
Conflicts: luci-app-yume-simhub
Replaces: luci-app-yume-simhub
Description: Yume SIMBridge LuCI UI and ARM64 SMS/SIP gateway
'''
preinst='''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/yume-simhub stop 2>/dev/null || true
/etc/init.d/yume-simhub disable 2>/dev/null || true
umask 077
mkdir -p /etc/yume-simbridge/data
if [ ! -f /etc/config/yume-simbridge ] && [ -f /etc/config/yume-simhub ]; then
 cp -p /etc/config/yume-simhub /etc/config/yume-simbridge
fi
if [ ! -e /etc/yume-simbridge/bootstrap.json ] && [ -f /etc/yume-simhub/bootstrap.json ]; then
 cp -p /etc/yume-simhub/bootstrap.json /etc/yume-simbridge/bootstrap.json
fi
if [ -d /etc/yume-simhub/data ] && [ -z "$(ls -A /etc/yume-simbridge/data 2>/dev/null)" ]; then
 cp -pR /etc/yume-simhub/data/. /etc/yume-simbridge/data/
fi
chmod 700 /etc/yume-simbridge /etc/yume-simbridge/data
exit 0
'''
postinst='''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
mkdir -p /etc/yume-simbridge
chmod 700 /etc/yume-simbridge
rm -f /tmp/luci-indexcache
/usr/lib/yume-simbridge/reload-rpcd.sh
if [ "$(uci -q get yume-simbridge.main.enabled)" = 1 ]; then
 /etc/init.d/yume-simbridge enable
 /etc/init.d/yume-simbridge start
fi
exit 0
'''
prerm='''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/yume-simbridge stop
/etc/init.d/yume-simbridge disable
exit 0
'''
entries=[('control',control.encode(),0o644),('conffiles',b'/etc/config/yume-simbridge\n',0o644),('preinst',preinst.encode(),0o755),('postinst',postinst.encode(),0o755),('prerm',prerm.encode(),0o755)]
control_data=tar_bytes(entries)
data=io.BytesIO()
with tarfile.open(fileobj=data,mode='w:gz',format=tarfile.GNU_FORMAT) as archive:
    for path in sorted(stage.rglob('*')):
        if path.is_file():
            info=archive.gettarinfo(str(path),arcname='./'+str(path.relative_to(stage)))
            info.uid=info.gid=0;info.uname=info.gname='root'
            info.mode=0o755 if path.stat().st_mode&0o111 else 0o644
            with path.open('rb') as src: archive.addfile(info,src)
# GL.iNet/OpenWrt opkg uses a gzip tar outer container (not Debian ar).
target=root/'dist'/f'luci-app-yume-simbridge_{label}_aarch64_cortex-a53_neon-vfpv4.ipk'
target.write_bytes(tar_bytes([('./debian-binary',b'2.0\n',0o644),('./control.tar.gz',control_data,0o644),('./data.tar.gz',data.getvalue(),0o644)]))
print(target)
