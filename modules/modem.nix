{ config, lib, pkgs, ... }:

let
  cfg = config.pro1x.modem;
  verbose = lib.optionalString cfg.verbose " -v";
in
{
  options.pro1x.modem = {
    enable = lib.mkEnableOption "Qualcomm modem userspace services (tqftpserv, rmtfs, ModemManager)";
    verbose = lib.mkEnableOption "verbose logging for the modem services";
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [
      (final: prev: {
        tqftpserv = prev.tqftpserv.overrideAttrs (old: {
          postPatch = ''
            substituteInPlace translate.c \
              --replace-fail '"/lib/firmware/"' '"/run/current-system/firmware/"'
          '';
        });
      })
    ];

    networking.modemmanager.enable = true;
    environment.systemPackages = with pkgs; [ libqmi qrtr ];

    systemd.services = {
      ModemManager = {
        wantedBy = [ "multi-user.target" ];
        wants = [ "rmtfs.service" "tqftpserv.service" ];
        after = [ "rmtfs.service" "tqftpserv.service" ];
      };

      tqftpserv = {
        description = "TFTP server over QRTR (firmware for the modem)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStart = "${pkgs.tqftpserv}/bin/tqftpserv${verbose}";
          Restart = "always";
          RestartSec = 1;
        };
      };
      rmtfs = {
        description = "Qualcomm remote filesystem service (modemst1/2, fsg, fsc)";
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          ExecStartPre = pkgs.writeShellScript "rmtfs-wait-modem" ''
            export PATH=${lib.makeBinPath [ pkgs.coreutils ]}
            i=0
            while [ "$i" -lt 180 ]; do
              for n in /sys/class/remoteproc/*/name; do
                [ -r "$n" ] && [ "$(cat "$n")" = modem ] && exit 0
              done
              i=$((i + 1))
              sleep 1
            done
            echo "modem remoteproc did not appear" >&2
            exit 1
          '';
          TimeoutStartSec = 240;
          ExecStart = "${pkgs.rmtfs}/bin/rmtfs -r -P -s${verbose}";
          Restart = "always";
          RestartSec = 1;
        };
        unitConfig.StartLimitIntervalSec = 0;
      };
    };
  };
}
