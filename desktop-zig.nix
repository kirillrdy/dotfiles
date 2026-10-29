{ pkgs }:
let
  dbusLibraries = import ./desktop-dbus-libs.nix { inherit pkgs; };
  gtkLibraries = import ./desktop-gtk-libs.nix {
    inherit pkgs;
    dbus = dbusLibraries;
  };
  audioLibraries = import ./desktop-audio-libs.nix { inherit pkgs; };
  pamLibraries = import ./desktop-pam-libs.nix { inherit pkgs; };
  textLibraries = import ./desktop-text-libs.nix { inherit pkgs; };
  # Keep the portal's xsettings namespace without retaining the daemon.
  portalSettingsSchemas =
    pkgs.runCommand "gnome-settings-daemon-${pkgs.gnome-settings-daemon.version}-gsettings-schemas" { }
      ''
        mkdir -p $out/share
        cp -r ${pkgs.gnome-settings-daemon}/share/gsettings-schemas/ $out/share/
      '';
  feedbackSound =
    pkgs.runCommand "desktop-volume-feedback.wav"
      {
        nativeBuildInputs = [ pkgs.sox ];
      }
      ''
        sox ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga -t wav -e signed-integer -b 16 "$out"
      '';
in
pkgs.stdenv.mkDerivation {
  pname = "desktop-zig";
  version = "0.1.0";
  outputs = [
    "out"
    "tests"
  ];
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
    pkgs.labwc
    pkgs.wayland-scanner
    pkgs.python3
  ];
  WAYLAND_PROTOCOLS_DIR = "${pkgs.wayland-protocols}/share/wayland-protocols";
  WLR_PROTOCOLS_DIR = "${pkgs.wlr-protocols}/share/wlr-protocols";
  buildInputs = [
    gtkLibraries.gtk
    gtkLibraries.layerShell
    pkgs.wayland
    pamLibraries
    textLibraries.xkbcommon
    audioLibraries.pipewire
  ];
  # Compile the former launcher's environment setup into the Zig executable.
  DESKTOP_RUNTIME_POWER_HELPER = "${placeholder "out"}/bin/desktop-zig";
  DESKTOP_RUNTIME_POWER_PKEXEC = "/run/wrappers/bin/pkexec";
  DESKTOP_RUNTIME_PIXBUF_LOADERS = "${textLibraries.rsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
  DESKTOP_RUNTIME_SOUND_FILE = "${feedbackSound}";
  DESKTOP_RUNTIME_DATA_DIRS = "${placeholder "out"}/share:${gtkLibraries.gtk}/share/gsettings-schemas/${gtkLibraries.gtk.name}:${pkgs.adwaita-icon-theme}/share:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${portalSettingsSchemas}/share/gsettings-schemas/gnome-settings-daemon-${pkgs.gnome-settings-daemon.version}";
  buildPhase = ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    zig build --prefix "$out" -Doptimize=ReleaseSafe
    # Executable interfaces required by SSH and the screenshot portal.
    for name in desktop-askpass grim slurp; do
      ln -s desktop-zig "$out/bin/$name"
    done
  '';
  doCheck = true;
  checkPhase = ''
    export GSETTINGS_BACKEND=memory
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export FONTCONFIG_FILE=${pkgs.fontconfig.out}/etc/fonts/fonts.conf
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$XDG_CACHE_HOME"
    python3 tests/check-desktop-greeter.py --binary "$out/bin/desktop-zig" --subcommand greeter
    zig build test-gtk-abi test-libc-abi -Doptimize=ReleaseSafe
    zig build test-runtime test-power test-portal-email -Doptimize=ReleaseSafe
    zig build test -Doptimize=ReleaseSafe
    mkdir -p "$TMPDIR/labwc-cfg"
    cat > "$TMPDIR/labwc-cfg/rc.xml" <<'EOF'
<labwc_config>
  <desktops><names><name>1</name></names></desktops>
  <keyboard><default /></keyboard>
</labwc_config>
EOF
    touch "$TMPDIR/labwc-cfg/autostart"
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
    labwc -C "$TMPDIR/labwc-cfg" &
    labwc_pid=$!
    trap 'kill -9 "$labwc_pid"' EXIT
    for attempt in $(seq 1 100); do
      test -S "$XDG_RUNTIME_DIR/wayland-0" && break
      sleep 0.05
    done
    export WAYLAND_DISPLAY=wayland-0
    export GDK_BACKEND=wayland
    G_DEBUG=fatal-criticals \
      GDK_PIXBUF_MODULE_FILE=${textLibraries.rsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      DESKTOP_PANEL_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons \
      "$out/bin/waybar-power-fixture"
    G_DEBUG=fatal-criticals \
      GDK_PIXBUF_MODULE_FILE=${textLibraries.rsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      DESKTOP_APPS_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons \
      "$out/bin/desktop-apps-fixture"
    G_DEBUG=fatal-criticals zig build test-settings -Doptimize=ReleaseSafe
    G_DEBUG=fatal-criticals \
      GDK_PIXBUF_MODULE_FILE=${textLibraries.rsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      zig build test-askpass -Doptimize=ReleaseSafe
    G_DEBUG=fatal-criticals \
      GDK_PIXBUF_MODULE_FILE=${textLibraries.rsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      zig build test-polkit -Doptimize=ReleaseSafe
    G_DEBUG=fatal-criticals \
      GDK_PIXBUF_MODULE_FILE=${textLibraries.rsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache \
      zig build test-screenshot -Doptimize=ReleaseSafe
  '';
  installPhase = ''
    # Keep test programs outside the desktop output.
    mkdir -p "$tests/bin"
    for name in desktop-apps-fixture desktop-audio-fixture desktop-battery-fixture desktop-backlight-fixture desktop-lock-fixture desktop-idle-fixture waybar-power-fixture labwc-switcher-fixture \
      desktop-pointer-fixture check-labwc-switcher; do
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
  '';
}
