{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "desktop-zig";
  version = "0.1.0";
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.fileFilter (file: file.hasExt "zig") ./.;
  };
  nativeBuildInputs = [
    pkgs.zig_0_17
    pkgs.pkg-config
    pkgs.makeWrapper
    pkgs.xorg-server
  ];
  buildInputs = [
    pkgs.gtk3
    pkgs.gtk-layer-shell
    pkgs.json-glib
    pkgs.curl
    pkgs.wayland
  ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    zig build --prefix "$out" -Doptimize=ReleaseSafe -j2
  '';
  doCheck = true;
  checkPhase = ''
    WB_PANEL_BINARY="$out/bin/waybar-panel" WB_CODEX_BINARY="$out/bin/waybar-codex" zig build test -Doptimize=ReleaseSafe -j2
    Xvfb :99 -nolisten tcp &
    xvfb_pid=$!
    trap 'kill "$xvfb_pid"' EXIT
    export DISPLAY=:99
    for attempt in $(seq 1 100); do
      test -S /tmp/.X11-unix/X99 && break
      sleep 0.05
    done
    G_DEBUG=fatal-criticals \
      GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      DESKTOP_PANEL_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons \
      "$out/bin/waybar-power-fixture"
    G_DEBUG=fatal-criticals GDK_BACKEND=x11 \
      GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      DESKTOP_APPS_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons \
      "$out/bin/desktop-apps-fixture"
  '';
  installPhase = ''
    wrapProgram "$out/bin/desktop-panel" \
      --set GDK_PIXBUF_MODULE_FILE ${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      --prefix XDG_DATA_DIRS : ${pkgs.adwaita-icon-theme}/share
    wrapProgram "$out/bin/desktop-apps" \
      --set GDK_PIXBUF_MODULE_FILE ${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    wrapProgram "$out/bin/waybar-panel" --prefix PATH : ${
      pkgs.lib.makeBinPath [
        pkgs.coreutils
        pkgs.wireplumber
        pkgs.upower
        pkgs.networkmanager
      ]
    }
  '';
}
