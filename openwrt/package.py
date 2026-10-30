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
control=f'''Package: luci-app-yume-simhub
Version: {label}
Architecture: aarch64_cortex-a53_neon-vfpv4
Maintainer: Yume SIM Hub
Section: luci
Priority: optional
Depends: libc, luci-base, rpcd, python3-light, python3-codecs, python3-logging, python3-uuid, python3-urllib, python3-ctypes, python3-openssl, libusb-1.0-0, alsa-utils, kmod-usb-audio, ca-bundle
Description: Yume SIM Hub LuCI UI and ARM64 SMS/SIP gateway
'''
postinst='''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
mkdir -p /etc/yume-simhub
chmod 700 /etc/yume-simhub
rm -f /tmp/luci-indexcache
/usr/lib/yume-simhub/reload-rpcd.sh
if [ "$(uci -q get yume-simhub.main.enabled)" = 1 ]; then
 /etc/init.d/yume-simhub enable
 /etc/init.d/yume-simhub start
fi
exit 0
'''
prerm='''#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
/etc/init.d/yume-simhub stop
/etc/init.d/yume-simhub disable
exit 0
'''
entries=[('control',control.encode(),0o644),('conffiles',b'/etc/config/yume-simhub\n',0o644),('postinst',postinst.encode(),0o755),('prerm',prerm.encode(),0o755)]
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
target=root/'dist'/f'luci-app-yume-simhub_{label}_aarch64_cortex-a53_neon-vfpv4.ipk'
target.write_bytes(tar_bytes([('./debian-binary',b'2.0\n',0o644),('./control.tar.gz',control_data,0o644),('./data.tar.gz',data.getvalue(),0o644)]))
print(target)
