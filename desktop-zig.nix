{ pkgs }:
let
  glLibraries = import ./desktop-gl-libs.nix { inherit pkgs; };
  audioLibraries = import ./desktop-audio-libs.nix { inherit pkgs; };
  pamLibraries = import ./desktop-pam-libs.nix { inherit pkgs; };
  inputLibraries = import ./desktop-input-libs.nix { inherit pkgs; };
  textLibraries = import ./desktop-text-libs.nix { inherit pkgs; };
  # Keep the portal's xsettings namespace without retaining the daemon.
  portalSettingsSchemas =
    pkgs.runCommand "gnome-settings-daemon-${pkgs.gnome-settings-daemon.version}-gsettings-schemas" { }
      ''
        mkdir -p $out/share
        cp -r ${pkgs.gnome-settings-daemon}/share/gsettings-schemas/ $out/share/
      '';
  codexIcon = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/kevinpita/codex-usage-extension/b88a5d0b02b37e9a06b8266bd5f29fa6a5f16213/codex-icon-22.png";
    hash = "sha256-kI1mut3KtZNahi8btZNSdogSrF+Z44yXqaZ4Jxf5L+E=";
  };
  feedbackSound =
    pkgs.runCommand "desktop-volume-feedback.wav"
      {
        nativeBuildInputs = [ pkgs.sox ];
      }
      ''
        sox ${pkgs.sound-theme-freedesktop}/share/sounds/freedesktop/stereo/audio-volume-change.oga -t wav -e signed-integer -b 16 "$out"
      '';
  # Pre-build Zig's compiler_rt, build_runner, maker, and translate-c once per toolchain.
  zigGlobalCache =
    pkgs.runCommand "zig-0.17-global-cache"
      {
        nativeBuildInputs = [ pkgs.zig_0_17 ];
      }
      ''
        mkdir -p src "$out"
        cat > src/main.zig <<'EOF'
        const std = @import("std");
        pub fn main() void {
            std.debug.print("{d}\n", .{@as(u64, 1)});
        }
        EOF
        cat > build.zig <<'EOF'
        const std = @import("std");
        pub fn build(b: *std.Build) void {
            const target = b.standardTargetOptions(.{});
            const optimize = b.standardOptimizeOption(.{});
            const header = b.addWriteFiles().add("c.h", "#include <stddef.h>\n");
            const tc = b.addTranslateC(.{ .root_source_file = header, .target = target, .optimize = optimize });
            const exe = b.addExecutable(.{
                .name = "warmup",
                .root_module = b.createModule(.{
                    .root_source_file = b.path("src/main.zig"),
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });
            exe.root_module.addImport("c", tc.createModule());
            b.installArtifact(exe);
        }
        EOF
        export ZIG_GLOBAL_CACHE_DIR="$out"
        zig build --prefix "$TMPDIR/out-safe" -Doptimize=ReleaseSafe
        zig build --prefix "$TMPDIR/out-debug" -Doptimize=Debug
        rm -rf "$out/tmp"
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
  src = if builtins.pathExists ./.git then builtins.fetchGit ./. else ./.;
  nativeBuildInputs = [
    pkgs.zig_0_17
    pkgs.pkg-config
    # xkbcli compiles the reference keymap for the native XKB tests.
    pkgs.libxkbcommon
    pkgs.removeReferencesTo
  ];
  passthru = {
    inherit pkgs zigGlobalCache;
  };
  dontStrip = true;
  WAYLAND_PROTOCOLS_DIR = "${pkgs.wayland-protocols}/share/wayland-protocols";
  WLR_PROTOCOLS_DIR = "${pkgs.wlr-protocols}/share/wlr-protocols";
  WAYLAND_XML = "${pkgs.wayland-scanner}/share/wayland/wayland.xml";
  # Case folding and normalization tables are generated from the UCD at build time.
  UNICODE_DATA_DIR = "${pkgs.unicode-character-database}/share/unicode";
  # Keysym names and characters are generated from xkbcommon's keysym header.
  XKB_KEYSYMS_HEADER = "${textLibraries.xkbcommon.dev}/include/xkbcommon/xkbcommon-keysyms.h";
  buildInputs = [
    # Text is matched, shaped, read and rasterized natively. HarfBuzz is the
    # reference the shaper is tested against.
    pkgs.harfbuzz
    inputLibraries
    # Kernel DRM headers, the reference for desktop-drm.zig and the GL tests.
    pkgs.libdrm
    # The native compositor composites with GLES through EGL on GBM buffers.
    glLibraries
    pkgs.libgbm
    pamLibraries
    # Audio and screen video use PipeWire's native protocol. Its headers are
    # test references, and an independent libpipewire consumer is a fixture.
    audioLibraries.pipewire
  ];
  # Compile the former launcher's environment setup into the Zig executable.
  DESKTOP_RUNTIME_POWER_HELPER = "${placeholder "out"}/bin/desktop-zig";
  DESKTOP_RUNTIME_POWER_PKEXEC = "/run/wrappers/bin/pkexec";
  DESKTOP_RUNTIME_SOUND_FILE = "${feedbackSound}";
  DESKTOP_RUNTIME_CODEX_ICON = "${codexIcon}";
  DESKTOP_RUNTIME_XLOCALE_DIR = "${textLibraries.composeData}/share/X11/locale";
  DESKTOP_RUNTIME_DATA_DIRS = "${placeholder "out"}/share:${pkgs.adwaita-icon-theme}/share:${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}:${portalSettingsSchemas}/share/gsettings-schemas/gnome-settings-daemon-${pkgs.gnome-settings-daemon.version}";
  buildPhase = ''
    cp -r ${zigGlobalCache} "$TMPDIR/zig-cache"
    chmod -R u+w "$TMPDIR/zig-cache"
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    # pkg-config supplies the declared libraries. Zig also turns every -L in
    # NIX_LDFLAGS into an RPATH, including unused propagated dependencies.
    NIX_LDFLAGS= zig build install --prefix "$out" -Dtest-bin=libexec/desktop-tests --release=safe
    # Executable interfaces required by SSH and the screenshot portal.
    for name in desktop-askpass grim slurp; do
      ln -s desktop-zig "$out/bin/$name"
    done
  '';
  doCheck = true;
  checkPhase = ''
    export GSETTINGS_BACKEND=memory
    export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    export FONTCONFIG_FILE=${
      pkgs.makeFontsConf {
        fontDirectories = [
          pkgs.adwaita-fonts
          pkgs.dejavu_fonts
        ];
      }
    }
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$XDG_CACHE_HOME"
    # Unit and ABI checks run without a display or a D-Bus session.
    NIX_LDFLAGS= zig build test --release=safe --summary all
  '';
  # Keep debug information without retaining the compiler through source paths.
  postFixup = ''
    find "$out" ''${tests:+"$tests"} -type f -exec remove-references-to -t ${pkgs.zig_0_17} {} +
    # Only test fixtures may load libpipewire; the desktop speaks the protocol itself.
    if grep -rlF ${audioLibraries.pipewire} "$out"; then
      echo "desktop output references libpipewire" >&2
      exit 1
    fi
    # Only the shaping reference test may load HarfBuzz.
    if grep -rlF ${pkgs.harfbuzz} "$out"; then
      echo "desktop output references HarfBuzz" >&2
      exit 1
    fi
  '';
  installPhase = ''
    mkdir -p "$out/share/applications"
    cat > "$out/share/applications/org.dotfiles.Settings.desktop" <<EOF_SETTINGS
    [Desktop Entry]
    Type=Application
    Name=Settings
    Comment=Manage networks and sound
    Exec=$out/bin/desktop-zig settings
    Icon=preferences-system
    Categories=Settings;System;
    StartupWMClass=org.dotfiles.Settings
    Terminal=false
    EOF_SETTINGS
    # Keep test programs outside the desktop output.
    mkdir -p "$tests/lib"
    mv "$out/libexec/desktop-tests" "$tests/bin"
    mv "$out/lib/libdesktop_secrets_test_token.so" "$tests/lib/"
    rmdir "$out/libexec"
    for name in $("$tests/bin/desktop-fixture" --list); do
      ln -sf desktop-fixture "$tests/bin/$name"
    done
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
