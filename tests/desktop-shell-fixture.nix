{ pkgs }:
let
  config = import ../desktop.nix {
    inherit pkgs;
    lib = pkgs.lib;
    enableLightDesktop = true;
  };
  panelConfig = pkgs.writeText "desktop-panel-config.json" config.content.environment.etc."xdg/desktop-panel/config.json".text;
in
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-shell-check";
  iconTheme = true;
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.glib
    pkgs.pipewire
    pkgs.wireplumber
  ];
  script =
    { desktop, dbusRun, ... }:
    ''
      ${dbusRun} python3 ${./check-desktop-shell.py} \
        --binary ${desktop}/bin/desktop-zig \
        --compositor ${desktop}/bin/desktop-zig \
        --panel-config ${panelConfig}
    '';
}
