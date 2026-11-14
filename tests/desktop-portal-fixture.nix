{ pkgs }:
let
  gtk =
    (import ../desktop-gtk-libs.nix {
      inherit pkgs;
      dbus = import ../desktop-dbus-libs.nix { inherit pkgs; };
    }).gtk;
in
import ./fixture.nix { inherit pkgs; } {
  name = "desktop-portal-check";
  fixture = {
    name = "desktop-portal-fixture";
    steps = "portal-fixture portal-chooser-fixture portal-print-fixture";
  };
  pygobject = true;
  withDesktop = true;
  gtkEnv = true;
  fonts = true;
  cacheDir = true;
  extraDataDirs = [ "${gtk}/share/gsettings-schemas/${gtk.name}" ];
  nativeBuildInputs = [
    pkgs.dbus
    pkgs.wlrctl
    pkgs.wtype
    pkgs.grim
  ];
  script =
    {
      fixture,
      dbusRun,
      headlessScript,
      ...
    }:
    ''
      export XDG_CONFIG_HOME="$TMPDIR/config"
      export XDG_DATA_HOME="$TMPDIR/data"
      mkdir -p "$XDG_CONFIG_HOME" "$XDG_DATA_HOME"
      ${dbusRun} python3 ${./check-desktop-portal.py} --binary ${fixture}/bin/desktop-portal-fixture
      ${dbusRun} python3 ${./check-desktop-portal-email.py} --binary ${fixture}/bin/desktop-portal-fixture

      ${headlessScript}
      export NO_AT_BRIDGE=1
      export GTK_USE_PORTAL=0
      export GIO_USE_VFS=local
      export G_DEBUG=fatal-criticals
      chooser_files="$TMPDIR/chooser-files"
      mkdir -p "$chooser_files"
      python3 - "$chooser_files" <<'PY'
      from pathlib import Path
      import sys
      for name in ('one.txt', '日本語.txt', 'report.txt'):
          (Path(sys.argv[1]) / name).write_text('fixture\n')
      PY
      GSETTINGS_BACKEND=memory ${dbusRun} ${fixture}/bin/desktop-portal-chooser-fixture "$chooser_files"
      ${dbusRun} python3 ${./check-desktop-portal-chooser.py} --binary ${fixture}/bin/desktop-portal-fixture
      export GTK_PRINT_BACKENDS=file
      GSETTINGS_BACKEND=memory ${dbusRun} ${fixture}/bin/desktop-portal-print-fixture "$chooser_files"
      ${dbusRun} python3 ${./check-desktop-portal-print.py} --binary ${fixture}/bin/desktop-portal-fixture
    '';
}
