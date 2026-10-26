{ config, lib, pkgs, ... }:

let
  cfg = config.pro1x.encryption;

  name = "cryptroot";
  userdata = "/dev/disk/by-partlabel/userdata";
  loopDev = "/dev/loop0";
  bootBytes = cfg.bootSize * 1024 * 1024;

  losetup = "${config.boot.initrd.systemd.package.util-linux}/bin/losetup";

  kernel = config.boot.kernelPackages.kernel;
  requiredKernelOptions = [ "BLK_DEV_LOOP" "BLK_DEV_DM" "DM_CRYPT" "CRYPTO_AES" "CRYPTO_XTS" "CRYPTO_SHA256" "EXT4_FS" ];
in
{
  options.pro1x.encryption = {
    enable = lib.mkEnableOption ''
      full-disk encryption of the root filesystem (LUKS2, unlocked in the initrd with the
      unl0kr on-screen keyboard). Needs a reflash with the encrypted flash script, see README'';

    bootSize = lib.mkOption {
      type = lib.types.ints.between 256 65536;
      default = 1024;
      description = ''
        Size in MiB of the unencrypted boot filesystem at the start of userdata. It holds
        one kernel, initrd and device tree per kept generation (about 70 MiB each).
        Must match what the flash script wrote: changing it needs a reflash.
      '';
    };

    allowDiscards = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pass TRIM through the encryption layer (keeps UFS fast; fstrim works). It reveals
        which blocks are in use, but not what is in them.
      '';
    };

    debugShell = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Give a root shell without a password if the initrd fails (reachable on the USB
        serial console). The disk stays locked, but anyone holding the phone can then poke
        at the initrd, so leave it off once everything works.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = lib.optional (kernel ? config && kernel.config ? isYes) {
      assertion = lib.all (o: kernel.config.isYes o) requiredKernelOptions;
      message = ''
        pro1x.encryption needs these options built into the kernel (=y): ${lib.concatStringsSep ", " requiredKernelOptions}.
        The kernel in packages/kernel has them; with a custom pro1x.kernelPackage add them to your config.
      '';
    };

    fileSystems = {
      "/" = lib.mkOverride 900 {
        device = "/dev/mapper/${name}";
        fsType = config.pro1x.rootFilesystem;
        options = lib.mkIf (config.pro1x.rootMountOptions != [ ]) config.pro1x.rootMountOptions;
        autoResize = true;
      };
      # The whole start of userdata, mounted for the bootloader installer. The filesystem
      # is only bootSize MiB big although the partition is much larger: never resize it.
      "/bootfs" = {
        device = userdata;
        fsType = "ext4";
        options = [ "noatime" ];
      };
      "/boot" = {
        device = "/bootfs/boot";
        fsType = "none";
        options = [ "bind" ];
        depends = [ "/bootfs" ];
      };
    };

    boot.initrd = {
      allowMissingModules = true;

      kernelModules = [ "goodix_ts" ];

      luks.devices.${name} = {
        device = loopDev;
        allowDiscards = cfg.allowDiscards;
        crypttabExtraOpts = [ "tries=0" ];
      };

      unl0kr = {
        enable = true;
        settings = {
          general.backend = lib.mkDefault "fbdev";
          keyboard.autohide = lib.mkDefault false;
        };
      };

      systemd = {
        emergencyAccess = lib.mkIf cfg.debugShell true;

        storePaths = [ losetup ];

        services = {
          pro1x-fde-loop = {
            description = "Expose the encrypted part of userdata as ${loopDev}";
            unitConfig.DefaultDependencies = false;
            requires = [ "dev-disk-by\\x2dpartlabel-userdata.device" ];
            after = [ "dev-disk-by\\x2dpartlabel-userdata.device" ];
            before = [ "systemd-cryptsetup@${name}.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = ''
              ${losetup} --detach ${loopDev} 2>/dev/null || true
              exec ${losetup} --offset ${toString bootBytes} ${loopDev} ${userdata}
            '';
          };

          "systemd-cryptsetup@${name}" = {
            overrideStrategy = "asDropin";
            requires = [ "pro1x-fde-loop.service" ];
            after = [ "pro1x-fde-loop.service" ];
          };

          # The panel is brought up by a built-in driver, but give it a moment before
          # unl0kr tries to open the framebuffer.
          unl0kr-agent = {
            overrideStrategy = "asDropin";
            preStart = ''
              for _ in $(seq 100); do
                [ -e /dev/fb0 ] && exit 0
                sleep 0.3
              done
              echo "no /dev/fb0 after 30 s; unl0kr will probably fail" >&2
            '';
          };
        };
      };
    };

    environment.systemPackages = [ pkgs.cryptsetup ];
  };
}
