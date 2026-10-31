{ pkgs }:
let
  compositorLibraries = import ./desktop-compositor-libs.nix { inherit pkgs; };
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
  # Keep build-tool libraries out of Zig's host linker search paths and RPATH.
  strictDeps = true;
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
      || file.hasExt "h"
      || file.hasExt "svg"
      || file.hasExt "xml"
      || file.name == "check-desktop-compositor.py"
      || file.name == "check-desktop-wallpaper.py"
      || file.name == "check-desktop-screenshot.py"
    ) ./.;
  };
  nativeBuildInputs = [
    pkgs.zig_0_17
    pkgs.pkg-config
    pkgs.wtype
    pkgs.grim
    pkgs.wlr-randr
    pkgs.wl-clipboard
    pkgs.dbus
    pkgs.wayland-scanner
    pkgs.python3
    pkgs.removeReferencesTo
  ];
  dontStrip = true;
  WAYLAND_PROTOCOLS_DIR = "${pkgs.wayland-protocols}/share/wayland-protocols";
  WLR_PROTOCOLS_DIR = "${pkgs.wlr-protocols}/share/wlr-protocols";
  buildInputs = [
    gtkLibraries.gtk
    gtkLibraries.layerShell
    pkgs.wayland
    compositorLibraries
    pkgs.libinput
    pkgs.libdrm
    pkgs.pixman
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
    # pkg-config supplies the declared libraries. Zig also turns every -L in
    # NIX_LDFLAGS into an RPATH, including unused propagated dependencies.
    NIX_LDFLAGS= zig build --prefix "$out" --release=safe
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
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
    "$out/bin/desktop-zig" compositor-only > "$TMPDIR/compositor.log" 2>&1 &
    compositor_pid=$!
    trap 'kill "$compositor_pid"' EXIT
    for attempt in $(seq 1 100); do
      test -S "$XDG_RUNTIME_DIR/wayland-0" && break
      sleep 0.05
    done
    export WAYLAND_DISPLAY=wayland-0
    export GDK_BACKEND=wayland
    export GDK_PIXBUF_MODULE_FILE=${textLibraries.rsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache
    export DESKTOP_PANEL_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons
    export DESKTOP_APPS_ICON_PATH=${pkgs.adwaita-icon-theme}/share/icons
    NIX_LDFLAGS= G_DEBUG=fatal-criticals zig build test compositor-fixture wallpaper-fixture --prefix "$out" --release=safe --summary all
    python3 tests/check-desktop-compositor.py --bin-dir "$out/bin" --wtype "$(command -v wtype)"
    python3 tests/check-desktop-wallpaper.py --bin-dir "$out/bin" --grim "$(command -v grim)" --wlr-randr "$(command -v wlr-randr)"
    PATH="$out/bin:$PATH" dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- python3 tests/check-desktop-screenshot.py --bin-dir "$out/bin"
    kill "$compositor_pid"
    wait "$compositor_pid" || true
    trap - EXIT
  '';
  # Keep debug information without retaining the compiler through source paths.
  postFixup = ''
    find "$out" "$tests" -type f -exec remove-references-to -t ${pkgs.zig_0_17} {} +
  '';
  installPhase = ''
    # Keep test programs outside the desktop output.
    mkdir -p "$tests/bin"
    for name in desktop-apps-fixture desktop-audio-fixture desktop-battery-fixture desktop-backlight-fixture desktop-lock-fixture desktop-idle-fixture waybar-power-fixture labwc-switcher-fixture \
      desktop-pointer-fixture desktop-compositor-fixture desktop-decoration-fixture desktop-wallpaper-fixture; do
      mv "$out/bin/$name" "$tests/bin/$name"
    done
    ln -s "$out/bin/desktop-zig" "$tests/bin/desktop-zig"
    mkdir -p "$out/share/dbus-1/services"
    cat > "$out/share/dbus-1/services/org.freedesktop.secrets.service" <<EOF_SECRETS_SERVICE
    [D-BUS Service]
    Name=org.freedesktop.secrets
    Exec=$out/bin/desktop-zig secrets
    SystemdService=desktop-secrets.service
    EOF_SECRETS_SERVICE
    mkdir -p "$out/share/dbus-1/system.d" "$out/share/dbus-1/system-services"
    cat > "$out/share/dbus-1/system.d/org.freedesktop.UPower.conf" <<'EOF_BATTERY_POLICY'
    <!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-BUS Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
    <busconfig>
      <policy user="root"><allow own="org.freedesktop.UPower"/></policy>
      <policy context="default"><allow send_destination="org.freedesktop.UPower"/></policy>
    </busconfig>
    EOF_BATTERY_POLICY
    cat > "$out/share/dbus-1/system-services/org.freedesktop.UPower.service" <<EOF_BATTERY_SERVICE
    [D-BUS Service]
    Name=org.freedesktop.UPower
    Exec=$out/bin/desktop-zig battery-monitor
    User=root
    SystemdService=desktop-battery.service
    EOF_BATTERY_SERVICE
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
