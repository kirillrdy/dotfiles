{
  desktop,
  name,
  steps,
  debug ? false,
  extraAttrs ? { },
}:
desktop.overrideAttrs (
  {
    pname = name;
    outputs = [ "out" ];
    buildPhase = ''
      export ZIG_GLOBAL_CACHE_DIR=$TMPDIR/zig-cache
      NIX_LDFLAGS= zig build ${steps} --prefix "$out" ${
        if debug then "-Doptimize=Debug -Dcpu=baseline" else "-Doptimize=ReleaseSafe"
      }
    '';
    doCheck = false;
    installPhase = "true";
  }
  // extraAttrs
)
