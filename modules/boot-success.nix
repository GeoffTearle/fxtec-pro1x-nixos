{ config, lib, pkgs, ... }:

let
  cfg = config.pro1x.bootSuccess;
in
{
  options.pro1x.bootSuccess.enable =
    lib.mkEnableOption "marking the boot slot as successful once the system is up (stops the bootloader from falling back to fastboot)"
    // { default = true; };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.qbootctl ]; 

    systemd.services.pro1x-boot-success = {
      description = "Mark the boot slot as successful (Qualcomm A/B)";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" "systemd-udev-settle.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        # Slot A is the one the flash scripts use; fall back to it when the current
        # slot cannot be read from the kernel command line (U-Boot boots us).
        ExecStart = pkgs.writeShellScript "pro1x-boot-success" ''
          ${pkgs.qbootctl}/bin/qbootctl -m || ${pkgs.qbootctl}/bin/qbootctl -m 0
        '';
      };
    };
  };
}
