#!/usr/bin/env bash
# First install with an encrypted root (pro1x.encryption.enable = true). Builds the
# userdata image on this computer, WITHOUT root, and flashes it with fastboot:
#
#   [ 0 .. boot_mib MiB ]  plain ext4 "pro1x-boot": /boot/extlinux, kernel, initrd (U-Boot reads this)
#   [ + 16 MiB ]           LUKS2 header (made by cryptsetup, your passphrase)
#   [ rest ]               the root filesystem image, encrypted with the volume key
#
# lib/artifacts.nix wraps this script and sets the PRO1X_* variables below. To try it by
# hand, set them to a boot tree directory, a root ext4 image, a U-Boot boot.img and a vbmeta.
#
# Needs free disk space of about (boot size + root image) in $PRO1X_WORKDIR (default: the
# current directory, not /tmp which may be RAM).
set -euo pipefail

: "${PRO1X_BOOT_TREE:?directory holding boot/ (extlinux + kernels)}"
: "${PRO1X_ROOTFS:?root filesystem image (ext4)}"
: "${PRO1X_UBOOT_IMG:?U-Boot boot.img}"
: "${PRO1X_VBMETA:?vbmeta.img}"
: "${PRO1X_BOOT_MIB:?size of the plain boot filesystem in MiB}"

mib=$((1024 * 1024))
boot_bytes=$((PRO1X_BOOT_MIB * mib))
luks_header=$((16 * mib))      # LUKS2 metadata + key slots; the data starts right after it
rootfs_bytes=$(stat -c %s "$PRO1X_ROOTFS")
total=$((boot_bytes + luks_header + rootfs_bytes))
payload_offset=$((boot_bytes + luks_header))

if [ -n "${PRO1X_PASSPHRASE:-}" ]; then
  # Non-interactive (tests, scripts): no questions asked.
  pass1=$PRO1X_PASSPHRASE
else
  echo "This ERASES userdata on the connected F(x)tec Pro1X (fastboot mode)."
  echo "The root filesystem will be encrypted with a passphrase you choose now."
  echo "Without the passphrase the data cannot be recovered."
  read -r -p "Type 'flash' to continue: " answer
  [ "$answer" = flash ] || exit 1

  read -r -s -p "New passphrase (8+ characters): " pass1 < /dev/tty; echo
  read -r -s -p "Repeat passphrase: " pass2 < /dev/tty; echo
  [ "$pass1" = "$pass2" ] || { echo "The passphrases differ." >&2; exit 1; }
fi
[ "${#pass1}" -ge 8 ] || { echo "Use at least 8 characters." >&2; exit 1; }

workdir="${PRO1X_WORKDIR:-$PWD}"
need_mib=$((total / mib + 64))
have_mib=$(df -Pm "$workdir" | awk 'NR == 2 { print $4 }')
if [ "$have_mib" -lt "$need_mib" ]; then
  echo "Not enough free space in $workdir: need about $need_mib MiB, have $have_mib MiB." >&2
  echo "Run this from a directory on a bigger disk, or set PRO1X_WORKDIR." >&2
  exit 1
fi

# Refuse an image that will not fit the phone's userdata partition (best effort).
size_hex=$(fastboot getvar partition-size:userdata 2>&1 | awk '/partition-size/ { print $2; exit }') || true
if [[ "${size_hex:-}" =~ ^0x[0-9a-fA-F]+$ ]] && [ "$total" -gt "$((size_hex))" ]; then
  echo "The image ($((total / mib)) MiB) is larger than userdata ($(((size_hex) / mib)) MiB)." >&2
  exit 1
fi

tmp=$(mktemp -d "$workdir/.pro1x-flash.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
img=$tmp/userdata.img
hdr=$tmp/header.img
key=$tmp/volume-key

echo "Building the userdata image ($((total / mib)) MiB)..."
truncate -s "$total" "$img"

# 1. The plain boot filesystem, in the first PRO1X_BOOT_MIB MiB of the image.
mke2fs -q -t ext4 -L pro1x-boot -E root_owner=0:0 -d "$PRO1X_BOOT_TREE" -F "$img" "${PRO1X_BOOT_MIB}M"

# 2. The LUKS2 header. A random volume key is chosen here so the root image can be
#    encrypted below without device-mapper (and thus without root). The header is formatted
#    in a scratch file and copied to where the container starts. Argon2 uses 256 MiB and a
#    fixed cost, which the phone can afford at every boot.
head -c 64 /dev/urandom > "$key"
truncate -s $((luks_header + mib)) "$hdr"
printf '%s' "$pass1" | cryptsetup luksFormat --batch-mode --type luks2 \
  --cipher aes-xts-plain64 --key-size 512 --hash sha256 --sector-size 512 \
  --offset $((luks_header / 512)) \
  --pbkdf argon2id --pbkdf-memory 262144 --pbkdf-parallel 4 --pbkdf-force-iterations 4 \
  --volume-key-file "$key" --key-file=- "$hdr"
printf '%s' "$pass1" | cryptsetup open --test-passphrase --key-file=- "$hdr"
dd if="$hdr" of="$img" bs=1M count=16 seek="$PRO1X_BOOT_MIB" conv=notrunc status=none

# 3. The root filesystem, encrypted exactly like dm-crypt aes-xts-plain64 does.
echo "Encrypting the root filesystem..."
pro1x-xts-encrypt "$key" "$img" "$payload_offset" < "$PRO1X_ROOTFS"

# 4. Check that what was written decrypts back to the start of the root image.
dd if="$img" bs="$mib" skip=$((payload_offset / mib)) count=4 status=none > "$tmp/enc-head"
truncate -s $((4 * mib)) "$tmp/check"
pro1x-xts-encrypt -d "$key" "$tmp/check" 0 < "$tmp/enc-head"
head -c $((4 * mib)) "$PRO1X_ROOTFS" | cmp - "$tmp/check" \
  || { echo "Self-check failed: the encrypted image does not decrypt back." >&2; exit 1; }
rm -f "$key" "$tmp/check" "$tmp/enc-head" "$hdr"

echo "Flashing..."
fastboot erase dtbo
fastboot flash boot_a "$PRO1X_UBOOT_IMG"
fastboot flash vbmeta_a "$PRO1X_VBMETA"
fastboot flash userdata "$img"
fastboot set_active a
fastboot reboot
echo "Done. At the first boot the screen asks for the passphrase."
