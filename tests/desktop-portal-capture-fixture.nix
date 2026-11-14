{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-portal-capture-check";
  fixture = {
    name = "desktop-portal-capture-fixtures";
    steps = "portal-capture-fixtures";
  };
  pygobject = true;
  withDesktop = true;
  gtkEnv = true;
  gdkPixbuf = false;
  iconTheme = false;
  fonts = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.pipewire
    pkgs.wireplumber
  ];
  env.GI_TYPELIB_PATH = "${pkgs.gdk-pixbuf}/lib/girepository-1.0";
  script =
    { fixture, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-portal-capture.py} \
        --binary ${fixture}/bin/desktop-portal-fixture \
        --video-consumer ${fixture}/bin/desktop-portal-video-fixture \
        --pointer ${fixture}/bin/desktop-pointer-fixture
    '';
}
