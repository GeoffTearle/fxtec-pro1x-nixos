#!/usr/bin/env bash
# Collect the Android sensor config (vendor partition inside "super", plus "persist")
# READ-ONLY, so we can see which sensor chips the Pro1X has and build the hexagonrpcd
# firmware directory from it.
#
#   sudo bash sensors-collect.sh
#
# Writes ./sensors-collect.tgz (small: JSON/config files only, no firmware blobs) and
# prints a summary. Nothing is written to the phone's partitions: super and persist are
# mounted read-only and unmounted again at the end.
set -u
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

here=$(pwd)
work=$(mktemp -d)
out=$work/out; mkdir -p "$out"
mnt_v=$work/vendor; mnt_p=$work/persist; mkdir -p "$mnt_v" "$mnt_p"
loopdev=""
cleanup() {
  umount "$mnt_v" 2>/dev/null; umount "$mnt_p" 2>/dev/null
  [ -n "$loopdev" ] && losetup -d "$loopdev" 2>/dev/null
  rm -f "$here/.vendor-ro.img"
  rm -rf "$work"
}
trap cleanup EXIT

py=$(command -v python3 || true)
if [ -z "$py" ]; then
  echo "python3 not found. Run:  nix shell nixpkgs#python3 -c sudo bash $0"
  exit 1
fi

super=/dev/disk/by-partlabel/super
[ -e "$super" ] || { echo "no $super"; exit 1; }

# --- parse the Android dynamic-partition (liblp) metadata in "super" -------------------
echo "== partitions in super"
"$py" - "$super" > "$work/lp.txt" <<'PY'
import struct, sys
f = open(sys.argv[1], 'rb')
f.seek(4096)
g = f.read(64)
magic, ssize = struct.unpack_from('<II', g, 0)
if magic != 0x616c4467:
    print("ERR geometry magic %#x (not liblp?)" % magic); sys.exit(1)
max_size, slots, lbs = struct.unpack_from('<III', g, 40)
f.seek(4096 + 4096 * 2)
h = f.read(512)
magic, maj, minr, hsize = struct.unpack_from('<IHHI', h, 0)
if magic != 0x414c5030:
    print("ERR header magic %#x" % magic); sys.exit(1)
tabs = struct.unpack_from('<12I', h, 80)
(p_off, p_n, p_sz), (e_off, e_n, e_sz) = tabs[0:3], tabs[3:6]
base = 4096 + 4096 * 2 + hsize
f.seek(base); blob = f.read(max(p_off + p_n * p_sz, e_off + e_n * e_sz) + 64)
exts = []
for j in range(e_n):
    ns, tt, td, ts = struct.unpack_from('<QIQI', blob, e_off + j * e_sz)
    exts.append((ns, tt, td, ts))
for i in range(p_n):
    ent = blob[p_off + i * p_sz: p_off + (i + 1) * p_sz]
    name = ent[:36].split(b'\0')[0].decode()
    attrs, first, num, grp = struct.unpack_from('<IIII', ent, 36)
    tot = sum(exts[first + k][0] for k in range(num))
    print("PART %s sectors=%d extents=%d" % (name, tot, num))
    for k in range(num):
        ns, tt, td, ts = exts[first + k]
        print("EXT %s %d %d %d %d" % (name, ns, tt, td, ts))
PY
grep -E "^(ERR|PART)" "$work/lp.txt"
grep -q "^ERR" "$work/lp.txt" && exit 1

# --- vendor: loop-mount a single linear extent, read-only ------------------------------
name=vendor_a
grep -q "^PART vendor_a " "$work/lp.txt" || name=$(awk '/^PART vendor/{print $2; exit}' "$work/lp.txt")
echo "== using $name"
mapfile -t ex < <(awk -v n="$name" '$1=="EXT" && $2==n' "$work/lp.txt")
if [ "${#ex[@]}" -eq 0 ]; then
  echo "no extents for $name"
else
  # Copy the extents, in order, into one temporary image next to this script (not in
  # /tmp, which may be RAM), then loop-mount that read-only. Deleted again at the end.
  total=0
  for e in "${ex[@]}"; do read -r _ _ ns _ _ _ <<<"$e"; total=$((total + ns)); done
  need_mb=$((total / 2048 + 64))
  avail_mb=$(df -Pm "$here" | awk 'NR==2{print $4}')
  echo "vendor is $((total / 2048)) MB in ${#ex[@]} extent(s); free here: ${avail_mb} MB"
  if [ "$avail_mb" -lt "$need_mb" ]; then
    echo "not enough free space in $here; run from a directory with $need_mb MB free"
  else
    img=$here/.vendor-ro.img
    rm -f "$img"; : > "$img"
    seekblk=0
    for e in "${ex[@]}"; do
      read -r _ _ ns tt td ts <<<"$e"
      [ "$tt" = 0 ] || { echo "non-linear extent, skipping: $e"; continue; }
      dd if="$super" of="$img" bs=512 skip="$td" seek="$seekblk" count="$ns" conv=notrunc status=none
      seekblk=$((seekblk + ns))
    done
    loopdev=$(losetup -f --show -r "$img")
    mount -o ro "$loopdev" "$mnt_v" 2>"$work/mnt.err" \
      || { echo "mount vendor failed: $(cat "$work/mnt.err")"; echo "fs type: $(blkid -o value -s TYPE "$loopdev")"; }
  fi
fi

mount -o ro /dev/disk/by-partlabel/persist "$mnt_p" 2>/dev/null || echo "persist mount failed"

echo "== vendor sensor config"
if mountpoint -q "$mnt_v"; then
  ls "$mnt_v/etc/sensors" 2>/dev/null | head -50
  mkdir -p "$out/vendor_etc"
  cp -a "$mnt_v/etc/sensors" "$out/vendor_etc/" 2>/dev/null
  ls "$mnt_v"/lib*/hw 2>/dev/null | grep -i sensor | head
  mkdir -p "$out/vendor_etc"
  cp -a "$mnt_v/etc/vintf/manifest.xml" "$out/vendor_etc/" 2>/dev/null
  cp -a "$mnt_v/build.prop" "$out/vendor_build.prop" 2>/dev/null
fi

echo "== DSP libraries (sensor modules, sns_registry skel)"
if mountpoint -q "$mnt_v"; then
  mkdir -p "$out/vendor_dsp"
  for dir in dsp lib/rfsa lib64/rfsa; do
    [ -d "$mnt_v/$dir" ] || continue
    ( cd "$mnt_v" && find "$dir" -type f \( -name 'libsns*' -o -name 'sns_*' -o -name '*registry*' \) ) | while read -r f; do
      mkdir -p "$out/vendor_dsp/$(dirname "$f")"
      cp -a "$mnt_v/$f" "$out/vendor_dsp/$f"
    done
    ( cd "$mnt_v" && find "$dir" -maxdepth 3 | sort ) > "$out/vendor_dsp/listing-$(echo "$dir" | tr / _).txt"
  done
  find "$out/vendor_dsp" -type f -name '*.so' | wc -l | sed 's/^/DSP libs copied: /'
fi

echo "== persist sensors"
if mountpoint -q "$mnt_p"; then
  ls -R "$mnt_p/sensors" 2>/dev/null | head -50
  mkdir -p "$out/persist"
  cp -a "$mnt_p/sensors" "$out/persist/" 2>/dev/null
fi

( cd "$out" && find . -type f | sort > FILES.txt && tar czf "$here/sensors-collect.tgz" . )
chown "${SUDO_USER:-root}" "$here/sensors-collect.tgz" 2>/dev/null
echo
echo "wrote $here/sensors-collect.tgz ($(du -h "$here/sensors-collect.tgz" | cut -f1)); $(wc -l < "$out/FILES.txt") files"
