{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-secrets-check";
  fixture = {
    name = "desktop-secrets-fixture";
    steps = "secrets-fixture secrets-pam secrets-pam-fixture";
    stripZigRef = true;
  };
  pygobject = true;
  withDesktop = true;
  runtimeDir = true;
  cacheDir = true;
  fontDirs = [
    pkgs.adwaita-fonts
    pkgs.dejavu_fonts
  ];
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.glib
    pkgs.wtype
    pkgs.libsecret
  ];
  script =
    {
      desktop,
      fixture,
      dbusRun,
      ...
    }:
    ''
      export DBUS_SYSTEM_BUS_ADDRESS=unix:path="$TMPDIR/nonexistent-system-bus"
      export G_DEBUG=fatal-criticals
      ${dbusRun} python3 ${./check-desktop-secrets.py} \
        --fixture ${fixture}/bin/desktop-secrets-fixture \
        --secret-tool ${pkgs.libsecret}/bin/secret-tool \
        --compositor ${desktop}/bin/desktop-zig
      python3 ${./check-desktop-secrets-pam.py} \
        --fixture ${fixture}/bin/desktop-secrets-pam-fixture \
        --bridge ${fixture}/lib/libpam_desktop_secrets.so \
        --token ${fixture}/lib/libdesktop_secrets_test_token.so \
        --permit ${pkgs.pam}/lib/security/pam_permit.so
    '';
}
