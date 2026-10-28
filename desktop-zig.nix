{ pkgs }:
let
  polkitLibraries = import ./desktop-polkit-libs.nix { inherit pkgs; };
  audioLibraries = import ./desktop-audio-libs.nix { inherit pkgs; };
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
    pkgs.xorg-server
    pkgs.wayland-scanner
    pkgs.python3
  ];
  WAYLAND_PROTOCOLS_DIR = "${pkgs.wayland-protocols}/share/wayland-protocols";
  WLR_PROTOCOLS_DIR = "${pkgs.wlr-protocols}/share/wlr-protocols";
  buildInputs = [
    pkgs.gtk3
    pkgs.gtk-layer-shell
    pkgs.wayland
    pkgs.pam
    pkgs.libxkbcommon
    polkitLibraries
    audioLibraries.wireplumber
    audioLibraries.pipewire
  ];
  # Compile the former launcher's environment setup into the Zig executable.
  DESKTOP_RUNTIME_POWER_HELPER = "${placeholder "out"}/bin/desktop-zig";
  DESKTOP_RUNTIME_POWER_PKEXEC = "/run/wrappers/bin/pkexec";
  DESKTOP_RUNTIME_PIXBUF_LOADERS = "${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
  DESKTOP_RUNTIME_SOUND_FILE = "${feedbackSound}";
  DESKTOP_RUNTIME_DATA_DIRS = "${placeholder "out"}/share:${pkgs.adwaita-icon-theme}/share:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}";
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
    python3 tests/check-desktop-greeter.py --binary "$out/bin/desktop-zig" --subcommand greeter
    zig build test-gtk-abi test-libc-abi -Doptimize=ReleaseSafe
    zig build test-runtime test-power -Doptimize=ReleaseSafe
    zig build test -Doptimize=ReleaseSafe
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
