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
  cairo =
    (pkgs.cairo.override {
      x11Support = false;
      xcbSupport = false;
    }).overrideAttrs
      {
        separateDebugInfo = false;
      };

  # The desktop renders text through Pango and FreeType; the Xft renderer is unused.
  pango =
    (pkgs.pango.override {
      inherit cairo;
      x11Support = false;
      withIntrospection = false;
    }).overrideAttrs
      (old: {
        pname = "desktop-pango";
        patches = (old.patches or [ ]) ++ [ ./pango-ft2-variations.patch ];
        separateDebugInfo = false;
        postFixup = "";
      });
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
  # The desktop renders SVG straight into Cairo and decodes PNG with Cairo, so
  # librsvg shares the text stack and needs neither GdkPixbuf nor its loader,
  # rsvg-convert, or the AVIF decoder for embedded images.
  rsvg =
    (pkgs.librsvg.override {
      inherit cairo pango;
      withIntrospection = false;
      withPixbufLoader = false;
    }).overrideAttrs
      (old: {
        pname = "desktop-rsvg";
        separateDebugInfo = false;
        buildInputs = pkgs.lib.remove pkgs.dav1d old.buildInputs;
        propagatedBuildInputs = pkgs.lib.remove pkgs.gdk-pixbuf old.propagatedBuildInputs;
        mesonFlags = old.mesonFlags ++ [
          "-Dpixbuf=disabled"
          "-Drsvg-convert=disabled"
          "-Davif=disabled"
        ];
        # Upstream generates rsvg-convert shell completions here.
        postInstall = "";
        disallowedRequisites = [
          pkgs.gdk-pixbuf
          pkgs.dav1d
        ];
      });
in
{
  inherit
    cairo
    pango
    xkbcommon
    rsvg
    ;
}
