{
  pkgs ? (builtins.getFlake (toString ./.)).inputs.nixpkgs.legacyPackages.${builtins.currentSystem},
}:
let
  desktop = import ./desktop-zig.nix { inherit pkgs; };
  devPrefix = "${toString ./.}/zig-out";
in
pkgs.mkShell {
  inputsFrom = [ desktop ];
  inherit (desktop)
    WAYLAND_PROTOCOLS_DIR
    WLR_PROTOCOLS_DIR
    DESKTOP_RUNTIME_POWER_PKEXEC
    DESKTOP_RUNTIME_PIXBUF_LOADERS
    DESKTOP_RUNTIME_SOUND_FILE
    ;
  DESKTOP_RUNTIME_POWER_HELPER = "${devPrefix}/bin/desktop-zig";
  DESKTOP_RUNTIME_DATA_DIRS = builtins.replaceStrings [ (builtins.placeholder "out") ] [
    devPrefix
  ] desktop.DESKTOP_RUNTIME_DATA_DIRS;
}
