#!/usr/bin/env bash
# Check the ADSP sensor stack end to end. Read-only.
#   sudo bash tools/sensors-check.sh 2>&1 | tee sensors-check.txt
# Then physically rotate the phone and move a hand over the top while it runs
# (the last step streams sensor events for 15 s).
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
sec() { printf '\n===== %s =====\n' "$*"; }

sec "hexagonrpcd service"
systemctl --no-pager -l status pro1x-hexagonrpcd 2>&1 | head -15
journalctl -b -u pro1x-hexagonrpcd --no-pager 2>&1 | tail -15

sec "ADSP + FastRPC"
for r in /sys/class/remoteproc/*; do echo "$(cat "$r/name"): $(cat "$r/state")"; done
ls -l /dev/fastrpc-adsp 2>&1

sec "registry/config served from $(echo /var/lib/hexagonrpcd)"
ls /var/lib/hexagonrpcd /var/lib/hexagonrpcd/sensors 2>&1 | head -20
find /var/lib/hexagonrpcd/sensors/persist/registry/registry -type f 2>/dev/null | wc -l | sed 's/^/registry files: /'

sec "QRTR services (the sensor service should appear once the ADSP is up)"
command -v qrtr-lookup >/dev/null && qrtr-lookup 2>&1 | head -30 || echo "qrtr-lookup not installed"

sec "kernel messages"
dmesg | grep -iE "fastrpc|sensor|pdr|pd.?mapper|adsp" | tail -15

sec "iio-sensor-proxy"
systemctl --no-pager status iio-sensor-proxy 2>&1 | head -8
busctl --system introspect net.hadess.SensorProxy /net/hadess/SensorProxy 2>&1 | grep -E "Has|Light|Orientation|Proximity" | head
udevadm info -q property -n /dev/fastrpc-adsp 2>/dev/null | grep -i mount

sec "live events for 15 s (rotate the phone, cover the top edge, shine a light)"
if command -v monitor-sensor >/dev/null; then
  timeout 15 monitor-sensor 2>&1 | head -40
else
  echo "monitor-sensor not found"
fi
echo; echo done
