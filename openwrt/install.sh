#!/bin/sh
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo 'Run as root'; exit 1; }
[ "$(uname -m)" = aarch64 ] || { echo 'ARM64 router required'; exit 1; }
[ -x /sbin/procd ] && [ -d /usr/share/luci ] || { echo 'OpenWrt with LuCI required'; exit 1; }
python3 -c 'import ssl,ctypes,urllib.request,logging,uuid; import encodings.idna' || { echo 'Install Python3, python3-pyusb, python3-urllib, python3-ctypes and CA certificates from your firmware feeds'; exit 1; }
command -v arecord >/dev/null && command -v aplay >/dev/null || { echo 'Install alsa-utils and matching kmod-usb-audio'; exit 1; }
/etc/init.d/yume-simhub stop 2>/dev/null || true
umask 077
mkdir -p /etc/yume-simhub
chmod 700 /etc/yume-simhub
# Copy application files; retain previously selected enable preference and credentials.
for path in usr www; do cp -R "root/$path/." "/$path/"; done
cp root/etc/init.d/yume-simhub /etc/init.d/yume-simhub
[ -f /etc/config/yume-simhub ] || cp root/etc/config/yume-simhub /etc/config/yume-simhub
chmod 755 /etc/init.d/yume-simhub /usr/libexec/rpcd/yume-simhub
rm -f /tmp/luci-indexcache
/usr/lib/yume-simhub/reload-rpcd.sh
/etc/init.d/yume-simhub start
echo 'Installed. Open LuCI → Services → Yume SIM Hub to pair and enable.'
