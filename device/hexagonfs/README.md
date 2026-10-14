# hexagonfs: sensor files for the ADSP

The Pro1X's accelerometer, gyroscope, magnetometer, ambient light and proximity
sensors are not on a Linux-visible bus. They belong to the ADSP (Qualcomm "SSC"),
which asks Linux to serve its configuration files over FastRPC. `hexagonrpcd`
(see `modules/sensors.nix`) does that, from this directory.

Layout (as `hexagonrpcd -R <dir>` expects):

    sensors/config/        <- Android /vendor/etc/sensors/config
    sensors/sns_reg.conf   <- Android /vendor/etc/sensors/sns_reg_config
    sensors/registry/      <- Android /mnt/vendor/persist/sensors/registry/registry

These files were copied read-only from this unit's own Android install with
`tools/sensors-collect.sh` (Fx_tec_Pro1X/QX1050_2_EEA, Android 11). The registry
holds default placement/calibration values. The ADSP rewrites its registry, so the
service keeps its own writable copy in /var/lib/hexagonrpcd, laid out the way
hexagonrpcd (pull request 27) wants it: `sensors/persist/registry/registry/` (this
directory's `registry/`), next to the `sns_reg_version` file the ADSP creates.
Nothing ever writes back to the Android persist partition.
Regenerate with: `sudo bash tools/sensors-collect.sh`.
