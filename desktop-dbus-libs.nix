{ pkgs }:
# Preserve systemd-aware D-Bus clients without linking the daemon/tool output of
# systemd. The D-Bus daemon itself remains a separate system service.
(pkgs.dbus.override { systemdMinimal = pkgs.systemdLibs; }).overrideAttrs (old: {
  pname = "desktop-dbus-client";
  mesonFlags = pkgs.lib.filter (flag: !(pkgs.lib.hasPrefix "--cross-file=" flag)) old.mesonFlags ++ [
    # Meson still needs a real systemctl for the daemon's activation files.
    # Only the D-Bus client library output is used by desktop-zig.
    "--cross-file=${pkgs.writeText "desktop-dbus-systemctl.ini" ''
      [binaries]
      systemctl = '${pkgs.systemdMinimal}/bin/systemctl'
    ''}"
  ];
})
