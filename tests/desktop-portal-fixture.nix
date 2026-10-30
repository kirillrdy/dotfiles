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
      zig build portal-fixture portal-chooser-fixture portal-print-fixture test-portal-email test-gtk-abi test-libc-abi --prefix "$out" -Doptimize=ReleaseSafe
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
      pkgs.labwc
      pkgs.wlrctl
      pkgs.wtype
      pkgs.grim
    ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export XDG_DATA_DIRS=${gtk}/share/gsettings-schemas/${gtk.name}:${pkgs.adwaita-icon-theme}/share
    export GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    export PYTHONDONTWRITEBYTECODE=1
    export PYTHONPATH=${./.}
    export XDG_CONFIG_HOME=$TMPDIR/config
    export XDG_CACHE_HOME=$TMPDIR/cache
    export XDG_DATA_HOME=$TMPDIR/data
    mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-portal.py} --binary ${fixture}/bin/desktop-portal-fixture

    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-portal-email.py} --binary ${fixture}/bin/desktop-portal-fixture

    export XDG_RUNTIME_DIR=$TMPDIR/runtime
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    mkdir -p "$TMPDIR/labwc"
    echo '<labwc_config><keyboard><default /></keyboard></labwc_config>' > "$TMPDIR/labwc/rc.xml"
    touch "$TMPDIR/labwc/autostart"
    export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
    export LABWC_UPDATE_ACTIVATION_ENV=false
    labwc -C "$TMPDIR/labwc" > "$TMPDIR/labwc.log" 2>&1 &
    compositor_pid=$!
    trap 'kill "$compositor_pid"' EXIT
    for attempt in $(seq 1 100); do
      test -S "$XDG_RUNTIME_DIR/wayland-0" && break
      kill -0 "$compositor_pid" || { cat "$TMPDIR/labwc.log"; exit 1; }
      sleep 0.05
    done
    test -S "$XDG_RUNTIME_DIR/wayland-0"
    export WAYLAND_DISPLAY=wayland-0
    export GDK_BACKEND=wayland
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
    export GTK_PRINT_BACKENDS=file
    GSETTINGS_BACKEND=memory \
      dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      ${fixture}/bin/desktop-portal-print-fixture "$chooser_files"
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-portal-print.py} --binary ${fixture}/bin/desktop-portal-fixture
    touch "$out"
  ''
