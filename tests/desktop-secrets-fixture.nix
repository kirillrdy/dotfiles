{ pkgs }:
let
  desktop = import ../desktop-zig.nix { inherit pkgs; };
  fixture = import ./fixture-build.nix {
    inherit desktop;
    name = "desktop-secrets-fixture";
    steps = "secrets-fixture secrets-pam secrets-pam-fixture";
    extraAttrs.postFixup = ''
      find "$out" -type f -exec remove-references-to -t ${pkgs.zig_0_17} {} +
    '';
  };
in
pkgs.runCommand "desktop-secrets-check"
  {
    FONTCONFIG_FILE = pkgs.makeFontsConf {
      fontDirectories = [
        pkgs.adwaita-fonts
        pkgs.dejavu_fonts
      ];
    };
    nativeBuildInputs = [
      (pkgs.python3.withPackages (python: [ python.pygobject3 ]))
      pkgs.dbus
      pkgs.glib
      pkgs.wtype
      pkgs.libsecret
      desktop
    ];
  }
  ''
    export XDG_RUNTIME_DIR="$TMPDIR/runtime"
    mkdir -m 700 "$XDG_RUNTIME_DIR"
    export DBUS_SYSTEM_BUS_ADDRESS=unix:path="$TMPDIR/nonexistent-system-bus"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    export G_DEBUG=fatal-criticals
    dbus-run-session --config-file=${pkgs.dbus}/share/dbus-1/session.conf -- \
      python3 ${./check-desktop-secrets.py} \
        --fixture ${fixture}/bin/desktop-secrets-fixture \
        --secret-tool ${pkgs.libsecret}/bin/secret-tool \
        --compositor ${desktop}/bin/desktop-zig
    python3 ${./check-desktop-secrets-pam.py} \
      --fixture ${fixture}/bin/desktop-secrets-pam-fixture \
      --bridge ${fixture}/lib/libpam_desktop_secrets.so \
      --token ${fixture}/lib/libdesktop_secrets_test_token.so \
      --permit ${pkgs.pam}/lib/security/pam_permit.so
    touch "$out"
  ''
