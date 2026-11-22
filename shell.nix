{
  pkgs ? (import ./default.nix { }).pkgs,
}:
let
  desktop = import ./default.nix { inherit pkgs; };
  devPrefix = "${toString ./.}/zig-out";
in
pkgs.mkShell {
  inputsFrom = [ desktop ];
  inherit (desktop)
    WAYLAND_PROTOCOLS_DIR
    WLR_PROTOCOLS_DIR
    WAYLAND_XML
    UNICODE_DATA_DIR
    DESKTOP_RUNTIME_POWER_PKEXEC
    DESKTOP_RUNTIME_SOUND_FILE
    DESKTOP_RUNTIME_CODEX_ICON
    ;
  DESKTOP_RUNTIME_POWER_HELPER = "${devPrefix}/bin/desktop-zig";
  DESKTOP_RUNTIME_DATA_DIRS =
    builtins.replaceStrings
      [ (builtins.placeholder "out") ]
      [
        devPrefix
      ]
      desktop.DESKTOP_RUNTIME_DATA_DIRS;
}
