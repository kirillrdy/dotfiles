{ pkgs }:
pkgs.stdenv.mkDerivation {
  pname = "desktop-zig";
  version = "0.1.0";
  outputs = [ "out" "tests" ];
  meta.mainProgram = "desktop-zig";
  src = pkgs.lib.fileset.toSource {
    root = ./.;
    fileset = pkgs.lib.fileset.fileFilter (
      file:
      file.hasExt "zig"
      || file.hasExt "svg"
      || file.hasExt "xml"
      || file.name == "check-desktop-greeter.py"
    ) ./.;
  };
  nativeBuildInputs = [
    pkgs.zig_0_17
    pkgs.pkg-config
    pkgs.makeWrapper
    pkgs.xorg-server
    pkgs.wayland-scanner
    pkgs.python3
  ];
  WAYLAND_PROTOCOLS_DIR = "${pkgs.wayland-protocols}/share/wayland-protocols";
  WLR_PROTOCOLS_DIR = "${pkgs.wlr-protocols}/share/wlr-protocols";
  buildInputs = [
    pkgs.gtk3
    pkgs.gtk-layer-shell
    pkgs.json-glib
    pkgs.wayland
    pkgs.polkit
  ];
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    zig build --prefix "$out" -Doptimize=ReleaseSafe
    # Compatibility names share the same executable; fixtures exercise these modes.
    for name in desktop-greeter desktop-power desktop-askpass desktop-screenshot \
      desktop-panel desktop-wallpaper desktop-notifications desktop-osd desktop-polkit \
      desktop-overview desktop-settings desktop-apps waybar-panel waybar-codex grim slurp; do
      ln -s desktop-zig "$out/bin/$name"
    done
  '';
  doCheck = true;
  checkPhase = ''
    export GSETTINGS_BACKEND=memory
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    python3 tests/check-desktop-greeter.py --binary "$out/bin/desktop-zig" --subcommand greeter
    zig build test-gtk-abi -Doptimize=ReleaseSafe
    zig build test-power -Doptimize=ReleaseSafe
    WB_PANEL_BINARY="$out/bin/waybar-panel" WB_CODEX_BINARY="$out/bin/waybar-codex" zig build test -Doptimize=ReleaseSafe
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
    G_DEBUG=fatal-criticals GDK_BACKEND=x11 zig build test-settings -Doptimize=ReleaseSafe
    G_DEBUG=fatal-criticals GDK_BACKEND=x11 \
      GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      zig build test-askpass -Doptimize=ReleaseSafe
    G_DEBUG=fatal-criticals GDK_BACKEND=x11 \
      GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      zig build test-polkit -Doptimize=ReleaseSafe
    G_DEBUG=fatal-criticals GDK_BACKEND=x11 \
      GDK_PIXBUF_MODULE_FILE=${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      zig build test-screenshot -Doptimize=ReleaseSafe
  '';
  installPhase = ''
    # Keep test programs and legacy component entry points outside the desktop output.
    mkdir -p "$tests/bin"
    for name in desktop-apps-fixture waybar-power-fixture labwc-switcher-fixture \
      desktop-pointer-fixture check-labwc-switcher \
      desktop-greeter desktop-power desktop-screenshot desktop-panel desktop-wallpaper \
      desktop-notifications desktop-osd desktop-polkit desktop-overview desktop-settings \
      desktop-apps waybar-panel waybar-codex; do
      mv "$out/bin/$name" "$tests/bin/$name"
    done
    ln -s "$out/bin/desktop-zig" "$tests/bin/desktop-zig"
    mkdir -p "$out/share/polkit-1/actions"
    cat > "$out/share/polkit-1/actions/org.dotfiles.desktop-power.policy" <<EOF
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE policyconfig PUBLIC "-//freedesktop//DTD PolicyKit Policy Configuration 1.0//EN" "http://www.freedesktop.org/standards/PolicyKit/1/policyconfig.dtd">
    <policyconfig>
      <action id="org.dotfiles.desktop-power">
        <description>Change the desktop power profile</description>
        <message>Authentication is required to change the power profile</message>
        <defaults>
          <allow_any>auth_admin</allow_any>
          <allow_inactive>auth_admin</allow_inactive>
          <allow_active>yes</allow_active>
        </defaults>
        <annotate key="org.freedesktop.policykit.exec.path">$out/bin/desktop-zig</annotate>
        <annotate key="org.freedesktop.policykit.exec.argv1">power</annotate>
      </action>
    </policyconfig>
    EOF
    wrapProgram "$out/bin/desktop-zig" \
      --run 'export DESKTOP_ZIG_INVOKED_AS="$0"' \
      --set DESKTOP_POWER_HELPER "$out/bin/desktop-zig" \
      --set DESKTOP_POWER_SUBCOMMAND power \
      --set DESKTOP_POWER_PKEXEC /run/wrappers/bin/pkexec \
      --prefix XDG_DATA_DIRS : "${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}" \
      --set GDK_PIXBUF_MODULE_FILE ${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      --prefix XDG_DATA_DIRS : "$out/share:${pkgs.adwaita-icon-theme}/share" \
      --set DESKTOP_OSD_SOUND_FILE ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga \
      --suffix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.coreutils
          pkgs.wireplumber
          pkgs.pipewire
          pkgs.networkmanager
          pkgs.upower
          pkgs.brightnessctl
        ]
      }
  '';
}
