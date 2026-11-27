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
in
{
  inherit composeData;
}
