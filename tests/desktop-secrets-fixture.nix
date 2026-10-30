{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = desktop.overrideAttrs (old: {
    pname = "desktop-secrets-fixture";
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      zig build secrets-fixture secrets-pam secrets-pam-fixture test-secrets --prefix "$out" -Doptimize=ReleaseSafe
    '';
    doCheck = false;
    installPhase = "true";
  });
in
pkgs.runCommand "desktop-secrets-check"
  {
    nativeBuildInputs = [
      (pkgs.python3.withPackages (python: [ python.pygobject3 ]))
      pkgs.dbus
      pkgs.glib
      pkgs.libsecret
      pkgs.labwc
    ];
  }
  ''
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    export DBUS_SYSTEM_BUS_ADDRESS=unix:path="$TMPDIR/nonexistent-system-bus"
    export G_DEBUG=fatal-criticals
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-secrets.py} \
        --fixture ${fixture}/bin/desktop-secrets-fixture \
        --secret-tool ${pkgs.libsecret}/bin/secret-tool \
        --compositor ${pkgs.labwc}/bin/labwc
    python3 ${./check-desktop-secrets-pam.py} \
      --fixture ${fixture}/bin/desktop-secrets-pam-fixture \
      --bridge ${fixture}/lib/libpam_desktop_secrets.so \
      --token ${fixture}/lib/libdesktop_secrets_test_token.so \
      --permit ${pkgs.pam}/lib/security/pam_permit.so
    touch "$out"
  ''
