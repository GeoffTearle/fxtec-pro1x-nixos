#!/usr/bin/env bash
# Read-only check of an encrypted install (pro1x.encryption.enable). Run on the phone:
#   sudo bash fde-check.sh 2>&1 | tee fde-check.txt
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
sec() { printf '\n===== %s =====\n' "$*"; }

sec "Mounts"
findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL / /boot /bootfs 2>&1

sec "Loop device behind the container (OFFSET must equal bootSize in bytes)"
losetup -l 2>&1

sec "dm-crypt mapping"
cryptsetup status cryptroot 2>&1

sec "LUKS header"
cryptsetup luksDump /dev/loop0 2>&1 | sed -n 1,40p

sec "Boot filesystem"
dumpe2fs -h /dev/disk/by-partlabel/userdata 2>/dev/null | grep -E "volume name|Block count|Block size|Free blocks|features"
ls -la /boot/extlinux /boot/nixos 2>&1 | head -30

sec "Cipher speed (one thread, RAM only)"
cryptsetup benchmark -c aes-xts-plain64 -s 512 2>&1 | tail -3

sec "Boot log: unlock path"
journalctl -b --no-pager 2>/dev/null | grep -iE "unl0kr|cryptsetup|pro1x-fde|ask-password|dm-crypt|goodix|fb0|loop0" | head -40

sec "Framebuffer + input seen by the kernel"
ls -l /dev/fb0 2>&1
grep -E "^(N: Name|H: Handlers)" /proc/bus/input/devices
echo
echo "done"
