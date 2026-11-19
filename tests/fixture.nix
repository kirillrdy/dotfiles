{ pkgs }:
# Compile fixtures in derivations and execute integration checks inside NixOS.
{
  name,
  vm ? true,
  nativeBuildInputs ? [ ],
  buildInputs ? [ ],
  python ? pkgs.python3,
  pygobject ? false,
  withDesktop ? false,
  fixture ? null,
  gtkEnv ? false,
  iconTheme ? gtkEnv,
  extraDataDirs ? [ ],
  fonts ? false,
  fontDirs ? pkgs.lib.optional fonts pkgs.dejavu_fonts,
  memorySettings ? false,
  noAtBridge ? false,
  runtimeDir ? false,
  cacheDir ? false,
  headless ? false,
  env ? { },
  script,
}:
let
  inherit (pkgs) lib;
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  builtFixture =
    if fixture == null then
      null
    else
      desktop.overrideAttrs (
        {
          pname = fixture.name;
          outputs = [ "out" ];
          buildPhase = ''
            cp -r ${desktop.zigGlobalCache} "$TMPDIR/zig-cache"
            chmod -R u+w "$TMPDIR/zig-cache"
            export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
            NIX_LDFLAGS= zig build ${fixture.steps} --prefix "$out" ${
              if (fixture.debug or false) then "-Doptimize=Debug -Dcpu=baseline" else "-Doptimize=ReleaseSafe"
            }
          '';
          doCheck = false;
          installPhase = "true";
        }
        // lib.optionalAttrs (fixture.stripZigRef or false) {
          postFixup = ''
            find "$out" -type f -exec remove-references-to -t ${pkgs.zig_0_17} {} +
          '';
        }
      );
  headlessScript = ''
    export XDG_RUNTIME_DIR="$TMPDIR/wayland-runtime"
    mkdir -m 700 -p "$XDG_RUNTIME_DIR"
    # Absolute paths survive tests creating their own private runtime directories.
    export WAYLAND_DISPLAY="$XDG_RUNTIME_DIR/wayland-0" GDK_BACKEND=wayland
    export WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1
    ${desktop}/bin/desktop-zig compositor-only > "$TMPDIR/compositor.log" 2>&1 &
    fixture_compositor_pid=$!
    trap 'kill "$fixture_compositor_pid" 2>/dev/null || true' EXIT
    for attempt in $(seq 1 100); do
      test -S "$WAYLAND_DISPLAY" && break
      if ! kill -0 "$fixture_compositor_pid" 2>/dev/null; then
        cat "$TMPDIR/compositor.log" >&2
        exit 1
      fi
      sleep 0.05
    done
    test -S "$WAYLAND_DISPLAY"
  '';
  dbusConfig = "${pkgs.dbus}/share/dbus-1/session.conf";
  dbusRun = "dbus-run-session --config-file=${dbusConfig} --";
  pythonPkg = if pygobject then pkgs.python3.withPackages (p: [ p.pygobject3 ]) else python;
  dataDirs = extraDataDirs ++ lib.optional iconTheme "${pkgs.adwaita-icon-theme}/share";
  body =
    if builtins.isFunction script then
      script {
        inherit
          desktop
          dbusConfig
          dbusRun
          headlessScript
          ;
        fixture = builtFixture;
      }
    else
      script;
  runtimeScript = pkgs.writeShellScript "${name}-run" (
    ''
      set -euo pipefail
      export TMPDIR=$(mktemp -d)
      cd "$TMPDIR"
    ''
    + setup
    + body
  );
  setup =
    lib.optionalString (pythonPkg != null) ''
      export PYTHONPATH=${./.}
      export PYTHONDONTWRITEBYTECODE=1
    ''
    + lib.optionalString gtkEnv ''
      export GSETTINGS_SCHEMA_DIR=${pkgs.gsettings-desktop-schemas}/share/gsettings-schemas/${pkgs.gsettings-desktop-schemas.name}/glib-2.0/schemas
    ''
    + lib.optionalString (dataDirs != [ ]) ''
      export XDG_DATA_DIRS=${lib.concatStringsSep ":" dataDirs}
    ''
    + lib.optionalString memorySettings ''
      export GSETTINGS_BACKEND=memory
    ''
    + lib.optionalString noAtBridge ''
      export NO_AT_BRIDGE=1
    ''
    + lib.optionalString runtimeDir ''
      export XDG_RUNTIME_DIR="$TMPDIR/runtime"
      mkdir -m 700 "$XDG_RUNTIME_DIR"
    ''
    + lib.optionalString cacheDir ''
      export XDG_CACHE_HOME="$TMPDIR/cache"
      mkdir -p "$XDG_CACHE_HOME"
    ''
    + lib.optionalString headless headlessScript;
  runner =
    pkgs.runCommand "${name}-runner"
      (
        {
          nativeBuildInputs =
            lib.optional (pythonPkg != null) pythonPkg
            ++ lib.optional withDesktop desktop
            ++ nativeBuildInputs
            ++ [ pkgs.makeWrapper ];
          inherit buildInputs;
        }
        // lib.optionalAttrs (fontDirs != [ ]) {
          FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = fontDirs; };
        }
        // env
      )
      ''
        mkdir -p "$out/bin"
        # Preserve setup-hook paths, but run every assertion after the VM boots.
        args=(--prefix PATH : "$PATH")
        for key in FONTCONFIG_FILE GI_TYPELIB_PATH XDG_DATA_DIRS ${lib.concatStringsSep " " (builtins.attrNames env)}; do
          if [[ -v $key ]]; then
            args+=(--set "$key" "''${!key}")
          fi
        done
        makeWrapper ${runtimeScript} "$out/bin/check" "''${args[@]}"
      '';
in
if !vm then
  pkgs.runCommand name
    {
      nativeBuildInputs = nativeBuildInputs;
      inherit buildInputs;
    }
    (
      setup
      + body
      + ''
        touch "$out"
      ''
    )
else
  pkgs.testers.runNixOSTest {
    inherit name;
    nodes.machine = {
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
      users.users.tester.isNormalUser = true;
      # These contract tests manage private compositors and mock services.
      # Production service wiring is covered separately by desktop-vm.nix.
      environment.systemPackages = [ runner ];
    };
    testScript = ''
      machine.start()
      machine.wait_for_unit("multi-user.target")
      with subtest(${builtins.toJSON name}):
          machine.succeed("su - tester -c ${runner}/bin/check", timeout=900)
    '';
  }
