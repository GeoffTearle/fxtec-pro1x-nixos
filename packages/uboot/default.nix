{ buildUBoot
, xxd
, lib
  # Entries "Boot previous generation 1..N" in the U-Boot menu (see modules/boot-menu.nix)
, previousGenerations ? 3
}:
let
  n = previousGenerations;
  entries = lib.concatMapStrings (i:
    "bootmenu_${toString i}=Boot previous generation ${toString i}=sysboot scsi 0#userdata any \${scriptaddr} /boot/extlinux/prev${toString i}.conf; pause\n"
  ) (lib.range 1 n);
in
(buildUBoot {
  version = "2026.10-rc-f8eb346";

  src = builtins.fetchGit {
    url = "https://github.com/u-boot/u-boot.git";
    rev = "f8eb3469e1a17c79b047b3fd38ae820e8816a115";
  };

  defconfig = "qcom_defconfig qcom-phone.config";
  extraMakeFlags = [ "DEVICE_TREE=qcom/sm6115-fxtec-pro1x" ];
  extraMeta.platforms = [ "aarch64-linux" ];

  extraConfig = ''
    CONFIG_CMD_HASH=y
    CONFIG_CMD_UFETCH=y
    CONFIG_CMD_SYSBOOT=y
  '';

  prePatch = ''
    substituteInPlace board/qualcomm/qcom-phone.env \
      --replace-fail 'bootcmd=bootefi bootmgr; pause; run menucmd' \
      'bootcmd=sysboot scsi 0#userdata any ''${scriptaddr} /boot/extlinux/extlinux.conf; pause; run menucmd'
    substituteInPlace board/qualcomm/qcom-phone.env \
      --replace-fail 'bootmenu_0=Boot=bootefi bootmgr; pause' \
      'bootmenu_0=Boot=sysboot scsi 0#userdata any ''${scriptaddr} /boot/extlinux/extlinux.conf; pause'

    # Phone-friendly access to older generations: the extlinux menu is a typed
    # prompt, so add fixed entries that load /boot/extlinux/prev<N>.conf (written
    # by modules/boot-menu.nix). Entries after Boot are renumbered to stay contiguous.
    ${lib.optionalString (n > 0) ''
      perl -0pi -e 's/^bootmenu_(\d+)=/"bootmenu_".($1 >= 1 ? $1 + ${toString n} : $1)."="/gme' board/qualcomm/qcom-phone.env
      printf '%s' ${lib.escapeShellArg entries} > prev-entries.txt
      perl -0pi -e 'BEGIN { local $/; open F, "<prev-entries.txt" or die; $e = <F>; } s/^(bootmenu_${toString (n + 1)}=)/$e$1/m or die' board/qualcomm/qcom-phone.env
    ''}

    # Bring-up fixes found on the Pro1X: USB gadget needs high-speed peripheral
    # mode + UTMI pipe clock (no SS PHY driver); UFS needs its GDSC.
    cat >> dts/upstream/src/arm64/qcom/sm6115-fxtec-pro1x.dts <<'EOF'

    &usb_dwc3 {
    	/delete-property/ usb-role-switch;
    	maximum-speed = "high-speed";
    	dr_mode = "peripheral";

    	phys = <&usb_hsphy>;
    	phy-names = "usb2-phy";
    };

    &usb {
    	qcom,select-utmi-as-pipe-clk;
    };
    EOF
    substituteInPlace drivers/clk/qcom/clock-sm6115.c \
      --replace-fail '	[GCC_USB30_PRIM_GDSC] = { 0x1a004 },' \
      '	[GCC_UFS_PHY_GDSC] = { 0x45004 },
    	[GCC_USB30_PRIM_GDSC] = { 0x1a004 },'
  '';

  filesToInstall = [
    "u-boot*"
    "dts/upstream/src/arm64/qcom/sm6115-fxtec-pro1x.dtb"
  ];
}).overrideAttrs (old: {
  # qcom-phone.env is converted to a C array with xxd.
  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ xxd ];
})
