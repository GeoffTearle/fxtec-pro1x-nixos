# Pro1X: btrfs root inside LUKS — fork plan

Status: phase 1 is implemented and verified off-device; building and flashing the image is what remains.
Phase 2 is optional and undecided.

## Progress tracker

| Phase | State | Lands in |
|---|---|---|
| 0 — fork the flake and pin it | NEXT, yours | host `~/src/config/flake.nix:244`, bookmark `btrfs` in the fork |
| 1 — btrfs root image, ext4 boot area kept | DONE off-device; image build + flash pending | fork: `modules/rootfs.nix:1-47`, `lib/artifacts.nix:14-17,40-94`, `modules/hardware.nix:19,141-147`, `modules/encryption.nix:62-67`, `flake.nix:69,79` |
| 2 — subvolumes (`root`, `home`, `nix`, `persist`, `log`) | later, needs a decision | fork: flash path or first-boot unit |
| 3 — snapshots and rollback of userland | out of scope | — |

## Resume instructions

1. Read this file.
2. Read the fork's `modules/rootfs.nix` and `lib/artifacts.nix:40-94` in full — they are the executable spec for
   phase 1.
3. Read `modules/hardware.nix:141-147` and `modules/encryption.nix:62-68` to see how `/` is defined; read
   `lib/artifacts.nix` before touching either builder.
4. `~/src/config` is outside the agent's filesystem grants by default. A session that needs the phase 0 line must ask
   for the grant (`uji --nono-allow /home/geofft/src/config`, or the path added to the uji profile plus
   `home-switch`) or leave that edit to the user.

## What the flake does today

Line numbers are for the current working tree (fork of upstream `579356e8`).

- `lib/artifacts.nix:50-56` builds the ext4 root filesystem with `nixos/lib/make-ext4-fs.nix`: a `fakeroot`+`faketime`
  build that copies the closure into `rootImage/nix/store`, drops `nix-path-registration`, sizes the image from `du`,
  runs `mkfs.ext4 -d`, then `fsck.ext4 -n -f` and shrinks with `resize2fs -M` before padding 16 MiB.
- `lib/artifacts.nix:58-93` is the btrfs builder (phase 1): same copy steps, `mkfs.btrfs -r` at `1.5 × du`, then
  `btrfs check --readonly`. `lib/artifacts.nix:94` picks one of the two from `pro1x.rootFilesystem`.
- `lib/artifacts.nix:95-100` builds `bootTree`: `boot/extlinux` plus one kernel/initrd/dtb per generation, populated by
  `boot.loader.generic-extlinux-compatible.populateCmd`.
- `modules/encryption.nix:62-67` pins `fileSystems."/"` with `lib.mkOverride 900`, device `/dev/mapper/cryptroot`,
  `autoResize = true`, and takes `fsType`/`options` from `pro1x.rootFilesystem`/`pro1x.rootMountOptions`.
  `:68-74` mounts `/bootfs` (the plain ext4 area) and `:75-80` binds `/boot` onto `/bootfs/boot`.
- `modules/encryption.nix:14` asserts a list of kernel options are `=y` (the check is `:53-59`): `BLK_DEV_LOOP`,
  `BLK_DEV_DM`, `DM_CRYPT`, `CRYPTO_AES`, `CRYPTO_XTS`, `CRYPTO_SHA256`, `EXT4_FS`.
- `scripts/flash-encrypted.sh` lays out userdata itself, unprivileged:
  `[0, bootSize MiB)` = ext4 `pro1x-boot` written by `mke2fs -d` (`:72`); then a 16 MiB LUKS2 header (`:80`, `--offset`
  is relative to the header start); then the root image encrypted with `pro1x-xts-encrypt` (`:90`), which reproduces
  `aes-xts-plain64` in userspace so the host needs neither root nor device-mapper. `:104` flashes the result to
  `userdata`.
- Kernel config `device/kernel/config.aarch64`: `CONFIG_EXT4_FS=y` (`:10981`), `CONFIG_BTRFS_FS=m` (`:10993`).

Consequence: btrfs is a change to *one image builder* plus four host settings. The LUKS layer, the XTS code, the boot
area, U-Boot, vbmeta and the slot logic are all filesystem-agnostic and must not be touched.

## Phase 0 — point the input at the fork (NEXT, yours)

- Create the bookmark the URL below points at, in `~/src/fxtec-pro1x-nixos`: `jj bookmark create btrfs -r @`.
  jj exports it as `refs/heads/btrfs`, which is what the `?ref=` needs; the bookmark follows the working copy, so
  later edits need no new commit.
- While iterating, point `~/src/config/flake.nix:244` at that checkout:

  ```nix
  pro1x.url = "git+file:///home/geofft/src/fxtec-pro1x-nixos?ref=refs/heads/btrfs";
  ```

  `git+file:` snapshots the working tree, dirty included, so each change is one `nix flake lock --update-input pro1x`
  away.
- Before any other host evaluates this flake — `work-mbp`, `UC`, the CI check — push the branch and switch the URL to
  `github:<you>/fxtec-pro1x-nixos?ref=refs/heads/btrfs`. A local path only resolves on L14G2, and `just check` runs on
  whichever host you are on.
- Keep the existing comment on that line: no `inputs.nixpkgs.follows`, because the cross-built kernel and U-Boot stay on
  the nixpkgs upstream tested them with.
- Confirm evaluation from an absolute path, after the lock update:

  ```
  nix eval --impure --raw --expr '(builtins.getFlake "/home/geofft/src/config").nixosConfigurations.pro1x.config.system.build.toplevel.drvPath'
  ```

Acceptance: that prints a `/nix/store/…drv`. No device interaction.

Skills to load: none — no skill governs Nix. Load `writing-plans` before editing this file.

## Phase 1 — btrfs root, ext4 boot area (DONE off-device)

Goal: `/` is btrfs inside the existing LUKS2 container; `/boot` stays ext4 because U-Boot's extlinux scan only reads
ext4. `/` mounts btrfs with `noatime ssd space_cache=v2 compress-force=zstd discard=async`, and `autoResize` still
grows it to the partition size at boot (`x-systemd.growfs`, btrfs is in nixpkgs' `resizableFSes`).

What landed, all inside the fork:

1. `modules/rootfs.nix` (new, whole file): `pro1x.rootFilesystem` (`enum [ "ext4" "btrfs" ]`, default `"ext4"`),
   `pro1x.rootMountOptions` (derived, `[ ]` for ext4 and the house set for btrfs), and a btrfs-only assertion that
   `kernel.config.isEnabled "BTRFS_FS"` — `isEnabled` accepts `=y` or `=m`, which the existing `isYes`-only form in
   `modules/encryption.nix` cannot.
2. `modules/hardware.nix:19` imports it next to `./encryption.nix`, and `:141-147` takes `fsType` and `options` from the
   two options. The plain (unencrypted) install gets the same treatment; it is the same code path.
3. `modules/encryption.nix:62-67` does the same for the LUKS case.
4. `flake.nix:69` registers `nixosModules.rootfs`; `:79` adds `rootfs` to `nixosModules.default.imports`.
5. `lib/artifacts.nix`: `:14` reads `cfg.pro1x.rootFilesystem or "ext4"` (the `or` mirrors the existing
   `encryption.enable or false`, so `mkArtifacts` still works for a config that does not import the module); `:17` pins
   one image UUID for both builders; `:40-46` hoists `populateImageCommands` out of the ext4 call; `:48` the shared
   `sdClosureInfo`; `:50-56` the ext4 builder unchanged apart from `uuid` and `inherit populateImageCommands`;
   `:58-93` the btrfs builder; `:94` the switch.
6. `scripts/flash-encrypted.sh:9-10,18`: wording only — `PRO1X_ROOTFS` takes any raw image. No logic change: `mke2fs`
   touches only the boot area, and XTS does not care what the payload contains.
7. `README.md:51` (module list), `:178-180` (rootfs is ext4 or btrfs), `:217-218` (`pro1x.rootFilesystem` row).

Two corrections to the original spec — both verified, do not "fix" them back:

- **`fileSystems."/".fsType = lib.mkForce "btrfs"` in a new module does not work here.** NixOS keeps only the
  definitions of `fileSystems."/"` at the winning priority, so `mkForce` (50) *replaces* the whole attrset and drops
  `device` and `autoResize`; evaluation then dies with `No device specified for mount point '/'`. That is why the
  fsType and the mount options come from the option inside the two modules that already own `/`, instead of from a
  third module overriding an attribute.
- **btrfs does have an offline checker.** `btrfs check --readonly` reads an unmounted image (nixpkgs' own
  `nixos/lib/make-btrfs-fs.nix` runs it), so the ext4 builder's `fsck` gate keeps its counterpart and the README needs
  no caveat.

Sizing: `1.5 × du -s -c -B 4096 --apparent-size ./rootImage`, rounded up to a whole MiB. `mkfs.btrfs --shrink` was
measured as the *worse* option (2629 MiB vs 2250 MiB for 1500 MiB of content in 20k files), so the image keeps its
headroom and growfs reclaims nothing — the slack simply stays allocated, which costs flash time and nothing else.

Verified off-device, on x86_64, no phone:

- Eval matrix over `nixosConfigurations.minimal-xc.extendModules` (ext4, ext4+encryption, btrfs, btrfs+encryption):
  `/` has the expected `fsType`, `device` (`/dev/disk/by-label/nixos` or `/dev/mapper/cryptroot`),
  `autoResize = true` and options `[ x-systemd.growfs x-initrd.mount … ]`; btrfs appears in
  `boot.initrd.kernelModules`; `system.fsPackages` gains `btrfs-progs`; every assertion is true. The two ext4 cases
  come out exactly as before this work.
- `lib/artifacts.nix` with a stand-in `system.build.toplevel` (`pkgs.python3`, encrypted variant): builds a 637 MiB
  image with label `nixos`, fsid `4444…`, sectorsize 4096, `/nix-path-registration` present, and
  `btrfs check --readonly` reporting `no error found`. The ext4 builder for the same stand-in gives 326 MiB, so the
  btrfs image is larger, as intended.
- `rootFilesystem = "ext4"` still selects `ext4-fs.img`; `"btrfs"` selects `btrfs-fs.img`.
- `nixpkgs-fmt` clean on every touched file. `modules/hardware.nix:167-171` (the udev rule) was already unformatted
  before this work and was left alone.

Still to verify, in order — the agent sandbox cannot do any of it (`nono` denies `git`, and evaluating
`system.build.toplevel` needs `builtins.fetchGit` of `firmware-fxtec-qx1050`):

- Build: `nix build -o result-rootfs .#pro1xImages.rootfs` and `nix build -o result-flash .#pro1xImages.flash` on
  L14G2, after phase 0. `result-rootfs` exists, is at least as large as the ext4 image was, and `file result-rootfs`
  reports a btrfs filesystem.
- `nix eval … .config.fileSystems."/".fsType` returns `btrfs` (the option won, and `/` still has its device).
- Flash with `./result-flash/bin/pro1x-flash` (it wipes `userdata`, including the working ext4 install).
- On the phone after unlock: `findmnt -no FSTYPE,OPTIONS /` shows `btrfs` with `compress-force=zstd`;
  `btrfs filesystem usage /` reports close to the full `userdata` size, proving growfs ran; `cryptsetup status
  cryptroot` is active.
- `systemctl --failed` empty and `journalctl -b -p err` free of btrfs errors.
- Two clean reboots, each unlocking with the passphrase (one attempt only — `tries=0`).

Skills to load: none — no skill governs Nix.

## Phase 2 — subvolumes (decide before starting)

Phase 1 yields one btrfs filesystem at subvolid 5, which cannot be snapshotted. The house layout is identical on every
btrfs host here — `system/L14G2/disk.nix:39-59`, and the same set in `system/vali-pad/disk.nix:47-64`,
`system/LGO/disk.nix:39-59` and `system/X330T/disk.nix:39-59`: LUKS2 `cryptroot` → btrfs label `nixos` → subvolumes
`root`→`/`, `home`→`/home`, `nix`→`/nix`, `persist`→`/persist`, `log`→`/var/log`, `swap`→`/swap` (16–64 GiB
swapfile), each mounted `subvol=<name> noatime ssd space_cache=v2 compress-force=zstd discard=async`, with `/persist`
and `/var/log` marked `neededForBoot` (`system/L14G2/disk.nix:74-75`).

Match that on the Pro1X with one substitution: no `/swap` subvolume. A 16 GiB swapfile is a lot of UFS wear on a
128 GB phone, and suspend-to-RAM needs no swap. If the phone needs a cushion under memory pressure, use zram instead —
`system/configs/system/zram.nix` sets zstd and 50%, and `system/configs/hardware/pi4-argon/hardware.nix:5` shows the
`mkOverride 40` idiom for opting in over its `mkForce false`.

Two routes to the subvolumes, neither free:

- **B1, build the subvolumes at image-build time.** Extend `lib/artifacts.nix:58-93` to loop-mount a scratch image,
  `mkfs.btrfs`, create the subvolumes, populate, unmount — then hand the finished image to the existing XTS path. Needs
  `sudo` for the mount, which the current design deliberately avoids; the flash itself still needs no root.
- **B2, convert on the phone.** At first boot: `btrfs subvolume create /root-new`, `cp -a --reflink=auto` everything into
  it, change the fork so `/` mounts `subvol=root-new` (the mount options already flow through
  `pro1x.rootMountOptions`, so `subvol=` is a one-line addition in `modules/rootfs.nix:9`), reboot, delete the top-level
  copies, then create the remaining subvolumes. No root on the host, one-shot and riskier.

Recommendation: B1 if snapshots matter, because it is reproducible and testable off-device. `/boot` stays on the ext4
area either way. Optional parity while in there: X330T also opens LUKS with
`--perf-no_read_workqueue --perf-no_write_workqueue` (`system/X330T/disk.nix:31-35`); the flake sets only
`allowDiscards` and `tries=0`, so the two perf flags can be merged into `crypttabExtraOpts` from our host module.

## Phase 3 — snapshots and rollback

Out of scope here. Note when planning it: `pro1x.bootMenu.generations` already gives kernel/initrd rollback from the
U-Boot menu, so btrfs snapshots would cover userland only, and the two must not be conflated when deciding what
"rollback" means on this device.

## Cross-phase invariants

- `mkArtifacts` keeps returning exactly `{ vbmetaImg, ubootImg, rootfsImg, flashScript, flashUbootScript, bootTree }`
  (`lib/artifacts.nix:159-161`); our `flake.nix` consumes `lib.mkImages` by those names.
- `pro1x.rootFilesystem` defaults to `"ext4"`, so every existing config and the flake's own `mkExample` hosts evaluate
  and behave as before. The ext4 mount options are still exactly `[ x-systemd.growfs x-initrd.mount ]`.
- userdata layout is fixed: ext4 boot area in `[0, pro1x.encryption.bootSize MiB)`, 16 MiB LUKS2 header, payload after.
  Changing it means every installed phone needs a reflash.
- `EXT4_FS=y` stays in the kernel config: `/bootfs` and the boot area are ext4 and mount before `/`.
- U-Boot, `vbmeta`, slot selection and the flaw that the stock ABL rejects `text_offset = -0x80000000` are untouched.
- Encryption stays userspace XTS; no `dm-crypt` and no root at flash time.

## Behavioural deltas to preserve

- The btrfs image is larger than the shrunk ext4 one (1.5 × apparent `du`, no shrink step) and keeps that slack on
  device; growfs grows to the partition size on top of it. Do not "fix" it by shrinking: `mkfs.btrfs --shrink` measures
  *larger*, and there is no post-hoc shrink worth running.
- The ext4 builder's `fsck.ext4 -n -f` gate has a btrfs counterpart, `btrfs check --readonly`. Do not drop it and do not
  replace it with a mount.
- `modules/hardware.nix` still owns the plain `/` definition and `modules/encryption.nix` the encrypted one. Do not move
  `/` into `modules/rootfs.nix`: whichever module defines `/` must also carry `device` and `autoResize`, because
  priorities replace the whole attrset.

## Workflow gotchas

- `fileSystems.<name>.options` is `nonEmptyListOf`: assigning `[ ]` is a type error. The two definitions use
  `lib.mkIf (opts != [ ]) opts` so ext4 keeps the `[ "defaults" ]` default plus systemd's own additions.
- `boot.initrd.supportedFilesystems` needs no explicit entry: `boot/stage-1.nix` derives it from the `fsNeededForBoot`
  entries of `fileSystems` (and `/` always qualifies), which is what pulls `btrfs` and `btrfs-progs` into the initrd.
- `nix build .#pro1xImages` fails: it is a set. Build leaves (`.#pro1xImages.rootfs`, `.flash`, `.uboot-img`).
- `nix eval .#…` from this repo fails on the relative `path:./pkgs/cme` input. Use
  `--impure --expr '(builtins.getFlake "/home/geofft/src/config").…'`.
- `flake.nix:88` references `./templates/host`, which does not exist at this rev, so `nix flake check` fails. Gate on
  targeted `nix build` / `nix eval` instead.
- Inside nono, `git` is denied, so anything that needs `builtins.fetchGit` (the firmware input, hence
  `system.build.toplevel`) fails in an agent session. Build and flash from a plain shell.
- Pointing `XDG_CACHE_HOME` at an empty dir makes nix re-download GitHub tarballs and can trip a NAR hash mismatch on
  `auto-cpufreq` against `flake.lock`. Do not do that on the build host; if it surfaces, `nix flake update auto-cpufreq`.
- Symptom "flash succeeded, boots straight to fastboot": ABL tried slot A and rejected the image. `fastboot getvar all`
  shows `slot-retry-count:a:0`, `slot-successful:a:no`. Re-run the whole flash — that fixed it once already, since the
  U-Boot image only boots with bytes 8..15 of the arm64 header zeroed (`lib/artifacts.nix` `ubootImg`).
- `crypttabExtraOpts = [ "tries=0" ]`: one wrong passphrase means a hard restart, not a retry.
- The flash script needs free space of about `bootSize` + root image in the working directory, and refuses `userdata`
  overflow.
- Inside nono, `/tmp` is not usable scratch; use `$TMPDIR`.
- `~/src/fxtec-pro1x-nixos` is outside the agent's filesystem grants by default, so an agent session cannot read or edit
  the fork. A session that hits `Permission denied` there must stop and ask for the grant
  (`uji --nono-allow /home/geofft/src/fxtec-pro1x-nixos`, or the path added to the uji profile plus `home-switch`) rather
  than working around it.
