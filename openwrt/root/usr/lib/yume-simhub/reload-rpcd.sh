#!/bin/sh
# GL.iNet may retain orphaned rpcd workers which keep an old plugin signature.
# Stop the management daemon, drain verified workers, then register fresh APIs.
/etc/init.d/rpcd stop
for pid in $(pidof rpcd); do
    [ "$(readlink "/proc/$pid/exe")" = /sbin/rpcd ] && kill -TERM "$pid" 2>/dev/null
done
attempt=0
while [ -n "$(pidof rpcd)" ] && [ "$attempt" -lt 3 ]; do
    sleep 1
    attempt=$((attempt + 1))
done
for pid in $(pidof rpcd); do
    [ "$(readlink "/proc/$pid/exe")" = /sbin/rpcd ] && kill -KILL "$pid" 2>/dev/null
done
/etc/init.d/rpcd start
