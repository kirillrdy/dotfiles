{ pkgs }:
let
  # Compose tables are text data, independent of the X11 client libraries.
  composeData =
    pkgs.runCommand "desktop-compose-data"
      {
        disallowedReferences = [ pkgs.libx11 ];
      }
      ''
        mkdir -p $out/share/X11
    cp -rL ${pkgs.libx11}/share/X11/locale $out/share/X11/locale
    chmod -R u+w $out/share/X11/locale
    # Several locale tables include the common UTF-8 table by absolute path.
    find $out/share/X11/locale -type f -exec sed -i \
      "s@${pkgs.libx11}/share/X11/locale@$out/share/X11/locale@g" {} +
      '';
  # Wayland supplies complete keymaps. Keep the compiler, layouts, and compose
  # data, without registry enumeration, X11 helpers, or interactive CLI tools.
  xkbcommon = (pkgs.libxkbcommon.override { withWaylandTools = false; }).overrideAttrs (old: {
    pname = "desktop-xkbcommon";
    outputs = [
      "out"
      "dev"
    ];
    separateDebugInfo = false;
    buildInputs = pkgs.lib.subtractLists [ pkgs.libxcb pkgs.libxml2 ] old.buildInputs;
    mesonFlags =
      (pkgs.lib.filter (flag: !(pkgs.lib.hasPrefix "-Dx-locale-root=" flag)) old.mesonFlags)
      ++ [
        "-Dx-locale-root=${composeData}/share/X11/locale"
        "-Denable-x11=false"
        "-Denable-xkbregistry=false"
        "-Denable-tools=false"
        "-Denable-docs=false"
      ];
  });
in
{
  inherit xkbcommon composeData;
}
