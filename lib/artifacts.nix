{ hostPkgs, ubootBase, lib, nixosConfig }:

let
  cfg = nixosConfig.config;
  # U-Boot with as many previous-generation menu entries as pro1x.bootMenu.generations
  uboot = ubootBase.override { previousGenerations = if cfg.pro1x.bootMenu.enable then cfg.pro1x.bootMenu.generations else 0; };
  toplevel = cfg.system.build.toplevel;
  params = import ./bootimg.nix;

  # pro1x.encryption.enable: root in a LUKS2 container, /boot in a plain ext4 filesystem
  # at the start of userdata (see modules/encryption.nix).
  encrypted = cfg.pro1x.encryption.enable or false;

  # AVB image with verification disabled; ABL refuses unsigned images otherwise.
  vbmetaImg = hostPkgs.runCommand "vbmeta.img" { nativeBuildInputs = [ hostPkgs.python3 ]; } ''
    python3 ${../scripts/mkvbmeta.py} $out
  '';

  # U-Boot wrapped as the Android "kernel" that the stock ABL loads.
  ubootImg = hostPkgs.runCommand "uboot.img"
    { nativeBuildInputs = [ hostPkgs.android-tools hostPkgs.gzip ]; } ''
    # U-Boot's arm64 Image header has text_offset = -0x80000000; the stock ABL
    # rejects that (straight back to fastboot). Linux has 0 there.
    cp ${uboot}/u-boot-nodtb.bin u-boot.bin
    chmod u+w u-boot.bin
    dd if=/dev/zero of=u-boot.bin bs=1 seek=8 count=8 conv=notrunc
    gzip --no-name -9 -c u-boot.bin > u-boot.bin.gz
    cat u-boot.bin.gz ${uboot}/sm6115-fxtec-pro1x.dtb > u-boot.bin.gz-dtb
    mkbootimg \
      --kernel u-boot.bin.gz-dtb \
      ${params.mkbootimgFlags params} \
      --output $out
  '';

  rootfsImg = hostPkgs.callPackage "${hostPkgs.path}/nixos/lib/make-ext4-fs.nix" {
    storePaths = [ toplevel ];
    volumeLabel = "nixos";
    compressImage = false;
    # With encryption /boot is a separate filesystem (bootTree below): the root only
    # carries the empty mount point.
    populateImageCommands =
      if encrypted then "mkdir -p ./files/boot" else ''
        mkdir -p ./files/boot
        ${cfg.boot.loader.generic-extlinux-compatible.populateCmd} -c ${toplevel} -d ./files/boot
      '';
  };

  # Contents of the plain boot filesystem of an encrypted install: boot/extlinux and
  # boot/nixos (U-Boot reads /boot/extlinux/extlinux.conf from the filesystem's root).
  bootTree = hostPkgs.runCommand "pro1x-boot-tree" { } ''
    mkdir -p $out/boot
    ${cfg.boot.loader.generic-extlinux-compatible.populateCmd} -c ${toplevel} -d $out/boot
  '';

  # Encrypts the root image like dm-crypt aes-xts-plain64 does, so the flash script needs
  # neither root nor device-mapper (see lib/xts-encrypt.c).
  xtsEncrypt = hostPkgs.runCommandCC "pro1x-xts-encrypt" { buildInputs = [ hostPkgs.openssl ]; } ''
    mkdir -p $out/bin
    cc -O2 -Wall -o $out/bin/pro1x-xts-encrypt ${./xts-encrypt.c} -lcrypto
  '';

  confirm = ''
    echo "This ERASES userdata on the connected F(x)tec Pro1X (fastboot mode)."
    read -r -p "Type 'flash' to continue: " a; [ "$a" = flash ] || exit 1
  '';

  # First install: U-Boot into boot_a (slot b does not boot on this phone), vbmeta, rootfs.
  plainFlashScript = hostPkgs.writeShellApplication {
    name = "pro1x-flash";
    runtimeInputs = [ hostPkgs.android-tools ];
    text = confirm + ''
      fastboot erase dtbo
      fastboot flash boot_a ${ubootImg}
      fastboot flash vbmeta_a ${vbmetaImg}
      fastboot flash userdata ${rootfsImg}
      fastboot set_active a
      fastboot reboot
    '';
  };

  # The same for an encrypted install: asks for a passphrase, builds the userdata image
  # (plain /boot + LUKS2 root) in the current directory and flashes it.
  encryptedFlashScript = hostPkgs.writeShellApplication {
    name = "pro1x-flash";
    runtimeInputs = with hostPkgs; [ android-tools coreutils cryptsetup e2fsprogs diffutils gawk xtsEncrypt ];
    text = ''
      export PRO1X_BOOT_TREE=${bootTree}
      export PRO1X_ROOTFS=${rootfsImg}
      export PRO1X_UBOOT_IMG=${ubootImg}
      export PRO1X_VBMETA=${vbmetaImg}
      export PRO1X_BOOT_MIB=${toString cfg.pro1x.encryption.bootSize}
      ${builtins.readFile ../scripts/flash-encrypted.sh}
    '';
  };

  flashScript = if encrypted then encryptedFlashScript else plainFlashScript;

  # Only U-Boot + vbmeta, userdata untouched (new U-Boot build, or recovery).
  flashUbootScript = hostPkgs.writeShellApplication {
    name = "pro1x-flash-uboot";
    runtimeInputs = [ hostPkgs.android-tools ];
    text = ''
      fastboot flash boot_a ${ubootImg}
      fastboot flash vbmeta_a ${vbmetaImg}
      fastboot set_active a
      fastboot reboot
    '';
  };
in
{
  inherit vbmetaImg ubootImg rootfsImg flashScript flashUbootScript;
  # Only meaningful with pro1x.encryption.enable.
  inherit bootTree;
}
