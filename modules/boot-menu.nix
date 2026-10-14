{ config, lib, pkgs, ... }:

# U-Boot's extlinux menu is a typed "Enter choice:" prompt, which the phone's
# keys (Up / Down / Enter only) cannot answer. Instead, the U-Boot boot menu
# (hold volume down at boot) has fixed entries "Boot previous generation 1..N"
# that load /boot/extlinux/prev1.conf .. prevN.conf. Those files hold a single
# generation each and are rewritten from extlinux.conf whenever it changes.
#
# The number of entries is compiled into U-Boot: after changing
# pro1x.bootMenu.generations, reflash U-Boot (nix build .#flash-uboot, or a full
# deploy). Keep it <= boot.loader.generic-extlinux-compatible.configurationLimit - 1.
let
  cfg = config.pro1x.bootMenu;

  split = pkgs.writeShellScript "pro1x-boot-menu-split" ''
    set -eu
    dir=/boot/extlinux
    src=$dir/extlinux.conf
    [ -f "$src" ] || exit 0
    # extlinux.conf: header, "Default" entry, then one entry per generation, newest
    # first. The newest generation is entry 2, so previous generation N is entry N+2.
    for n in $(seq 1 ${toString cfg.generations}); do
      ${pkgs.gawk}/bin/awk -v want=$((n + 2)) '
        /^[[:space:]]*LABEL[[:space:]]/ { entry++; if (entry == want) label = $2 }
        entry == want { body = body $0 "\n" }
        END {
          if (body == "") exit 1
          print "TIMEOUT 0"
          print "PROMPT 0"
          print "DEFAULT " label
          printf "%s", body
        }
      ' "$src" > "$dir/.prev$n.tmp" || { rm -f "$dir/.prev$n.tmp" "$dir/prev$n.conf"; continue; }
      mv -f "$dir/.prev$n.tmp" "$dir/prev$n.conf"
    done
    # Drop files left over from a larger setting.
    for f in $dir/prev*.conf; do
      [ -e "$f" ] || continue
      n=''${f##*/prev}; n=''${n%.conf}
      [ "$n" -le ${toString cfg.generations} ] || rm -f "$f"
    done
  '';
in
{
  options.pro1x.bootMenu = {
    enable = lib.mkEnableOption "U-Boot menu entries for previous generations" // { default = true; };
    generations = lib.mkOption {
      type = lib.types.ints.between 0 9;
      default = 3;
      description = ''
        How many previous generations get an entry in the U-Boot menu (hold volume
        down at boot). Built into U-Boot, so reflash it after changing this.
      '';
    };
  };

  config = lib.mkIf (cfg.enable && cfg.generations > 0) {
    systemd.services.pro1x-boot-menu = {
      description = "Write /boot/extlinux/prev*.conf for the U-Boot menu";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = split;
      };
    };
    # Runs again whenever the bootloader install rewrites extlinux.conf.
    systemd.paths.pro1x-boot-menu = {
      wantedBy = [ "multi-user.target" ];
      pathConfig.PathChanged = "/boot/extlinux/extlinux.conf";
    };
  };
}
