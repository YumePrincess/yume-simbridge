#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo 'Run as root'; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo 'ARM64 router required'; exit 1; }
[ -x /sbin/procd ] && [ -d /usr/share/luci ] || { echo 'OpenWrt with LuCI required'; exit 1; }
python3 -c 'import ssl,ctypes,urllib.request,logging,uuid; import encodings.idna' || { echo 'Install Python3, python3-pyusb, python3-urllib, python3-ctypes and CA certificates from your firmware feeds'; exit 1; }
command -v arecord >/dev/null && command -v aplay >/dev/null || { echo 'Install alsa-utils and matching kmod-usb-audio'; exit 1; }
/etc/init.d/yume-simhub stop 2>/dev/null || true
/etc/init.d/yume-simhub disable 2>/dev/null || true
/etc/init.d/yume-simbridge stop 2>/dev/null || true
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
# Copy application files; retain previously selected enable preference and credentials.
for path in usr www; do cp -R "root/$path/." "/$path/"; done
cp root/etc/init.d/yume-simbridge /etc/init.d/yume-simbridge
[ -f /etc/config/yume-simbridge ] || cp root/etc/config/yume-simbridge /etc/config/yume-simbridge
chmod 755 /etc/init.d/yume-simbridge /usr/libexec/rpcd/yume-simbridge
if command -v opkg >/dev/null 2>&1 && opkg status luci-app-yume-simhub >/dev/null 2>&1; then
    opkg remove luci-app-yume-simhub
fi
rm -f /tmp/luci-indexcache
/usr/lib/yume-simbridge/reload-rpcd.sh
/etc/init.d/yume-simbridge start
echo 'Installed. Open LuCI → Services → Yume SIMBridge to pair and enable.'
