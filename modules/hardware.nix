{ config, lib, pkgs, ... }:

# The Pro1X itself: kernel, device tree, firmware, initrd, U-Boot boot entries,
# consoles, root filesystem, udev rules. Everything every host needs.
let
  cfg = config.pro1x;

  # The touchscreen reports over the whole 2160 rows, but with display.topGap/bottomGap
  # the desktop only covers the rows in between, so map touches onto that area:
  # y' = (y * 2160 - top) / (2160 - top - bottom) as a libinput calibration matrix.
  even = g: g - lib.mod g 2;
  gapTop = even cfg.display.topGap;
  gapBottom = even cfg.display.bottomGap;
  active = 2160 - gapTop - gapBottom;
  touchMatrix = "1 0 0 0 ${toString (2160.0 / active)} ${toString (0.0 - gapTop * 1.0 / active)}";
in
{
  # Opt-in extras that need hooks in the boot path.
  imports = [ ./encryption.nix ./rootfs.nix ];

  options.pro1x = {
    kernelPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.pro1x-kernel;
      defaultText = lib.literalExpression "pkgs.pro1x-kernel";
      description = ''
        Kernel to use. The flake sets this to a kernel cross-compiled on an x86_64
        build host (fast) while the rest of the system stays native aarch64
        (substituted from cache.nixos.org, or built under binfmt).
      '';
    };

    serial.enable = lib.mkEnableOption "USB serial gadget console (ttyGS0) for debugging";

    verbose = lib.mkEnableOption "verbose kernel/systemd logging and earlycon on the debug UART";

    display.topGap = lib.mkOption {
      type = lib.types.ints.between 0 400;
      default = 0;
      example = 40;
      description = ''
        Leave this many lines at the top of the panel unused (black), e.g. to hide
        rounded corners. Same mechanism as bottomGap.
      '';
    };

    display.bottomGap = lib.mkOption {
      type = lib.types.ints.between 0 400;
      default = 0;
      example = 60;
      description = ''
        Leave this many lines at the bottom of the panel unused (black; the desktop
        gets 2160 minus topGap minus this many lines), e.g. to hide dead rows on a
        replacement panel. The panel timing, and so the 60 Hz refresh, is unchanged.
        Rounded down to an even number. Needs the panelgap kernel patch (a kernel
        rebuild). The display controller moves the picture and fills the gaps with black.
      '';
    };

    consoleRotation = lib.mkOption {
      type = lib.types.nullOr (lib.types.enum [ 0 1 2 3 ]);
      default = null;
      example = 1;
      description = ''
        Rotate the text console (boot messages, TTY login) with fbcon=rotate:N:
        0 normal (portrait), 1 clockwise, 2 upside down, 3 counter-clockwise.
        Use 1 or 3 to read the console in landscape with the keyboard slid out; try
        both, only one is right way up. Does not affect U-Boot or the desktop.
      '';
    };
  };

  config = {
    nixpkgs = {
      hostPlatform = "aarch64-linux";
      overlays = [ (import ../overlay.nix) ];
      config.allowUnfree = true; # Qualcomm firmware
    };

    boot.kernelPackages = pkgs.linuxPackagesFor cfg.kernelPackage;

    hardware = {
      deviceTree = {
        enable = true;
        name = "qcom/sm6115-fxtec-pro1x.dtb";
        filter = "*sm6115-fxtec-pro1x*";
      };
      # Device firmware lives under qcom/sm6115/Fxtec/QX1050/ (matches the DTS).
      firmware = [ pkgs.pro1x-firmware ];
      enableRedistributableFirmware = true; # linux-firmware: a610 SQE, ath10k, qca BT
      # Qualcomm remoteproc loaders want uncompressed images.
      firmwareCompression = "none";
    };

    boot.initrd = {
      # Everything needed to reach UFS is built in (see device/kernel/pro1x.fragment).
      includeDefaultModules = false;
      compressor = "zstd";
      systemd = {
        enable = true;
        tpm2.enable = false;
      };
    };

    # Boot: stock ABL -> U-Boot (boot_a) -> /boot/extlinux/extlinux.conf on the ext4
    # rootfs. Every `nixos-rebuild`/deploy adds a U-Boot menu entry; old generations
    # stay selectable (hold volume-down at boot).
    boot.loader.grub.enable = false;
    boot.loader.generic-extlinux-compatible = {
      enable = true;
      configurationLimit = 5;
    };
    boot.loader.timeout = lib.mkDefault 3;

    boot.kernelParams = [
      "loglevel=4"
      # Serial console on the debug UART (GENI @ 0x4a90000), then the panel.
      # Last console listed becomes /dev/console.
      "console=ttyMSM0,115200n8"
    ]
    ++ lib.optionals cfg.serial.enable [
      "console=ttyGS0,115200"
      "systemd.log_target=console"
    ]
    ++ lib.optionals cfg.verbose [
      "earlycon=msm_geni_serial,0x4a90000"
      "ignore_loglevel"
      "systemd.log_level=debug"
    ]
    ++ [ "console=tty1" ]
    ++ lib.optionals (cfg.display.topGap != 0) [
      "panel_boe_bf060y8m_aj0.top_gap=${toString cfg.display.topGap}"
      "msm.display_top_gap=${toString cfg.display.topGap}"
    ]
    ++ lib.optionals (cfg.display.bottomGap != 0) [
      "panel_boe_bf060y8m_aj0.bottom_gap=${toString cfg.display.bottomGap}"
      "msm.display_bottom_gap=${toString cfg.display.bottomGap}"
    ]
    ++ lib.optional (cfg.consoleRotation != null) "fbcon=rotate:${toString cfg.consoleRotation}";

    # The Pro1X userdata partition has 4096-byte sectors.
    fileSystems."/" = lib.mkDefault {
      device = "/dev/disk/by-label/nixos";
      fsType = cfg.rootFilesystem;
      options = lib.mkIf (cfg.rootMountOptions != [ ]) cfg.rootMountOptions;
      autoResize = true;
    };

    # Register the initial closure on first boot (image is built offline).
    boot.postBootCommands = ''
      if [ -f /nix-path-registration ]; then
        ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration
        touch /etc/NIXOS
        ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
        rm -f /nix-path-registration
      fi
    '';

    console.earlySetup = true;

    systemd.services."serial-getty@ttyGS0" = lib.mkIf cfg.serial.enable {
      enable = true;
      wantedBy = [ "multi-user.target" ];
      serviceConfig.Restart = "always";
    };

    # dma-buf providers for the camera, haptics device for feedbackd.
    services.udev.extraRules = builtins.readFile ../device/udev/60-pro1x.rules
      + lib.optionalString (gapTop + gapBottom != 0) ''
        # Touch follows the display gap (pro1x.display.topGap / bottomGap)
        ACTION!="remove", SUBSYSTEM=="input", ENV{ID_INPUT_TOUCHSCREEN}=="1", ENV{LIBINPUT_CALIBRATION_MATRIX}="${touchMatrix}"
      '';
    users.groups.feedbackd = { };

    system.stateVersion = lib.mkDefault "26.05";
  };
}
