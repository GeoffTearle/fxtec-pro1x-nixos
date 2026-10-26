{ config, lib, ... }:

let
  cfg = config.pro1x;
  kernel = config.boot.kernelPackages.kernel;

  # The house set: no access-time writes, btrfs on flash, free-space tree, zstd, and
  # batched discards that survive allowDiscards on the LUKS layer.
  btrfsMountOptions = [ "noatime" "ssd" "space_cache=v2" "compress-force=zstd" "discard=async" ];
in
{
  options.pro1x = {
    rootFilesystem = lib.mkOption {
      type = lib.types.enum [ "ext4" "btrfs" ];
      default = "ext4";
      description = ''
        Filesystem of the root partition. /boot stays ext4 either way: U-Boot's
        extlinux scan only reads ext4. Changing it needs a reflash with the
        matching image (see README).
      '';
    };

    rootMountOptions = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Mount options for /, derived from pro1x.rootFilesystem. Set by this
        module; add to it rather than replacing it.
      '';
    };
  };

  config = lib.mkMerge [
    { pro1x.rootMountOptions = lib.mkIf (cfg.rootFilesystem == "btrfs") btrfsMountOptions; }

    (lib.mkIf (cfg.rootFilesystem == "btrfs") {
      # A module is enough: the initrd carries it, because / is mounted there.
      assertions = lib.optional (kernel ? config && kernel.config ? isEnabled) {
        assertion = kernel.config.isEnabled "BTRFS_FS";
        message = ''
          pro1x.rootFilesystem = "btrfs" needs CONFIG_BTRFS_FS=m or =y in the kernel.
          The kernel in packages/kernel has it; with a custom pro1x.kernelPackage add it.
        '';
      };
    })
  ];
}
