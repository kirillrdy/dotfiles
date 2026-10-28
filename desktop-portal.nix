{
  pkgs,
  desktop,
  upstream ? pkgs.xdg-desktop-portal,
}:
# Preserve the build-time interface metadata used by portal backends, while
# the runtime package contains only desktop-zig and its activation files.
pkgs.runCommand "desktop-portal"
  {
    version = upstream.version;
    meta.description = "Native desktop-zig portal broker";
  }
  ''
    mkdir -p "$out/libexec" "$out/share/dbus-1/services" \
      "$out/share/dbus-1/interfaces" "$out/share/pkgconfig" \
      "$out/lib/systemd/user"
    ln -s ${desktop}/bin/desktop-zig "$out/libexec/xdg-desktop-portal"
    cp ${upstream}/share/dbus-1/interfaces/*.xml "$out/share/dbus-1/interfaces/"
    cat > "$out/share/pkgconfig/xdg-desktop-portal.pc" <<EOF_PC
    prefix=$out
    datadir=\''${prefix}/share
    interfaces_dir=\''${datadir}/dbus-1/interfaces
    Name: xdg-desktop-portal
    Description: Desktop portal interfaces
    Version: ${upstream.version}
    EOF_PC
    cat > "$out/share/dbus-1/services/org.freedesktop.portal.Desktop.service" <<EOF_BUS
    [D-BUS Service]
    Name=org.freedesktop.portal.Desktop
    Exec=${desktop}/bin/desktop-zig portal
    SystemdService=xdg-desktop-portal.service
    EOF_BUS
    cat > "$out/lib/systemd/user/xdg-desktop-portal.service" <<EOF_UNIT
    [Unit]
    Description=Native desktop portal broker
    PartOf=graphical-session.target
    After=graphical-session.target
    [Service]
    Type=dbus
    BusName=org.freedesktop.portal.Desktop
    ExecStart=${desktop}/bin/desktop-zig portal
    Restart=on-failure
    EOF_UNIT
  ''
