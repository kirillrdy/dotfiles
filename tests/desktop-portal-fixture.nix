{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = desktop.overrideAttrs {
    pname = "desktop-portal-fixture";
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build portal-fixture --prefix "$out" -Doptimize=ReleaseSafe
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
    ];
  }
  ''
    export PYTHONDONTWRITEBYTECODE=1
    export HOME=$TMPDIR/home
    mkdir -p "$HOME"
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-portal.py} --binary ${fixture}/bin/desktop-portal-fixture
    touch "$out"
  ''
