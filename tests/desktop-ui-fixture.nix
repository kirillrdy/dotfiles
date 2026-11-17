{ pkgs }:
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-ui-check";
  fixture = {
    name = "desktop-integration-tests";
    steps = "test-binary -Dintegration-tests=true";
  };
  pygobject = true;
  gtkEnv = true;
  memorySettings = true;
  cacheDir = true;
  headless = true;
  fontDirs = [
    pkgs.adwaita-fonts
    pkgs.dejavu_fonts
  ];
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wtype
    pkgs.wlrctl
    pkgs.wlr-randr
  ];
  script =
    {
      desktop,
      fixture,
      dbusRun,
      ...
    }:
    ''
      export DESKTOP_PANEL_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons
      export DESKTOP_APPS_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons
      export G_DEBUG=fatal-criticals

      # Screen pixel checks run before other fixtures map their windows.
      ${fixture}/bin/desktop-tests
      for name in apps dash widgets settings polkit screenshot; do
        ${desktop.tests}/bin/desktop-$name-fixture
      done
      ${desktop.tests}/bin/desktop-askpass-fixture ${desktop}/bin/desktop-zig
      mkdir clients
      ln -s ${desktop.tests}/bin/* clients/
      ln -s ${desktop}/bin/desktop-zig clients/desktop-zig
      python3 ${./check-desktop-window.py} --binary clients/desktop-window-fixture
      python3 ${./check-desktop-compositor.py} --bin-dir clients --wtype ${pkgs.wtype}/bin/wtype
      python3 ${./check-desktop-askpass.py} --binary ${desktop}/bin/desktop-zig --wtype ${pkgs.wtype}/bin/wtype
      ${dbusRun} python3 ${./check-desktop-command.py} clients/desktop-command-fixture
      ${dbusRun} python3 ${./check-desktop-notifications.py} clients
      ${dbusRun} python3 ${./check-desktop-date-menu.py} clients
      ${dbusRun} python3 ${./check-desktop-codex.py} clients
    '';
}
