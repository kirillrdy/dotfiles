{ pkgs }:
let
  pam = import ../desktop-pam-libs.nix { inherit pkgs; };
in
pkgs.runCommand "desktop-pam-check"
  {
    nativeBuildInputs = [
      pkgs.zig_0_17
      pkgs.pkg-config
    ];
    buildInputs = [ pam ];
  }
  ''
    export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
    printf '#include <stdlib.h>\n#include <security/pam_appl.h>\n' > pam-abi.h
    zig translate-c -lc $(pkg-config --cflags pam) pam-abi.h > pam-abi.zig
    zig build-exe -OReleaseSafe -lc -lpam -rpath ${pam}/lib $(pkg-config --libs-only-L pam) \
      --dep pam -Mroot=${./desktop-pam-fixture.zig} -Mpam=pam-abi.zig -femit-bin=pam-fixture
    mkdir "$TMPDIR/pam.d"
    echo 'Private fixture message: 東京' > "$TMPDIR/message"
    cat > "$TMPDIR/pam.d/system-allow" <<EOF
    auth required ${pkgs.pam}/lib/security/pam_echo.so file=$TMPDIR/message
    auth required ${pkgs.pam}/lib/security/pam_permit.so
    account required ${pkgs.pam}/lib/security/pam_permit.so
    EOF
    cat > "$TMPDIR/pam.d/client-allow" <<EOF
    auth required pam_permit.so
    account required pam_permit.so
    EOF
    cat > "$TMPDIR/pam.d/system-deny" <<EOF
    auth required ${pkgs.pam}/lib/security/pam_deny.so
    EOF
    cat > "$TMPDIR/pam.d/system-expired" <<EOF
    auth required ${pkgs.pam}/lib/security/pam_permit.so
    account required ${pkgs.pam}/lib/security/pam_debug.so acct=acct_expired
    EOF
    cat > "$TMPDIR/pam.d/module-missing" <<EOF
    auth required /nonexistent/desktop-pam-module.so
    EOF
    cat > "$TMPDIR/pam.d/system-unix" <<EOF
    account required ${pkgs.pam}/lib/security/pam_unix.so
    EOF
    ./pam-fixture "$TMPDIR/pam.d"
    touch "$out"
  ''
