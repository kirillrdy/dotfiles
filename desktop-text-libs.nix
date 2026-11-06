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

  # GTK renders through Pango/Cairo; its separate Xft renderer is unused.
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
  # The SVG loader must use the same text stack so it does not retain a second
  # Pango build and its Xft dependencies through the pixbuf loader cache.
  rsvgBuild =
    (pkgs.librsvg.override {
      inherit cairo pango;
      withIntrospection = false;
    }).overrideAttrs
      {
        pname = "desktop-rsvg";
        separateDebugInfo = false;
      };
  # Only the shared SVG loader is used at runtime. Keep rsvg-convert and its
  # completions in the upstream build used for checks, outside the desktop.
  rsvg =
    pkgs.runCommand "desktop-svg-loader-${rsvgBuild.version}"
      {
        nativeBuildInputs = [ pkgs.patchelf ];
        disallowedReferences = [ rsvgBuild ];
      }
      ''
        mkdir -p "$out/lib"
        cp -a ${rsvgBuild}/lib/librsvg-2.so* "$out/lib/"
        cp -a ${rsvgBuild}/lib/gdk-pixbuf-2.0 "$out/lib/"
        chmod -R u+w "$out"
        loader="$out/lib/gdk-pixbuf-2.0/2.10.0/loaders/libpixbufloader_svg.so"
        patchelf --print-rpath "$loader" > loader-rpath
        substituteInPlace loader-rpath --replace-fail '${rsvgBuild}/lib' "$out/lib"
        patchelf --set-rpath "$(cat loader-rpath)" "$loader"
        substituteInPlace "$out/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache" \
          --replace-fail '${rsvgBuild}' "$out"
      '';
in
{
  inherit
    cairo
    pango
    xkbcommon
    rsvg
    ;
}
