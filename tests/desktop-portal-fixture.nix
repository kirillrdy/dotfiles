{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  gtk =
    (import ../desktop-gtk-libs.nix {
      inherit pkgs;
      dbus = import ../desktop-dbus-libs.nix { inherit pkgs; };
    }).gtk;
  fixture = desktop.overrideAttrs {
    pname = "desktop-portal-fixture";
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build portal-fixture portal-chooser-fixture --prefix "$out" -Doptimize=ReleaseSafe
    '';
    doCheck = false;
    installPhase = "true";
  };
in
pkgs.runCommand "desktop-portal-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (p: [ p.pygobject3 ]))
      pkgs.dbus
      pkgs.xorg-server
      pkgs.xdotool
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${gtk}/share/gsettings-schemas/${gtk.name}:${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    export PYTHONDONTWRITEBYTECODE=1
    export XDG_CONFIG_HOME=$TMPDIR/config
    export XDG_CACHE_HOME=$TMPDIR/cache
    export XDG_DATA_HOME=$TMPDIR/data
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-portal.py} --binary ${fixture}/bin/desktop-portal-fixture

    Xvfb :92 -nolisten tcp &
    chooser_xvfb=$!
    trap 'kill "$chooser_xvfb"' EXIT
    for attempt in $(seq 1 100); do
      test -S /tmp/.X11-unix/X92 && break
      sleep 0.05
    done
    export DISPLAY=:92
    export GDK_BACKEND=x11
    export NO_AT_BRIDGE=1
    export GTK_USE_PORTAL=0
    export GIO_USE_VFS=local
    export G_DEBUG=fatal-criticals
    chooser_files=$TMPDIR/chooser-files
    mkdir -p "$chooser_files"
    python3 - "$chooser_files" <<'PY'
    from pathlib import Path
    import sys
    for name in ('one.txt', '日本語.txt', 'report.txt'):
        (Path(sys.argv[1]) / name).write_text('fixture\n')
    PY
    GSETTINGS_BACKEND=memory \
      dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      ${fixture}/bin/desktop-portal-chooser-fixture "$chooser_files"
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-portal-chooser.py} --binary ${fixture}/bin/desktop-portal-fixture
    touch "$out"
  ''
