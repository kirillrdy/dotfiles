{ pkgs }:
let
  cairo = (pkgs.cairo.override {
    x11Support = false;
    xcbSupport = false;
  }).overrideAttrs {
    separateDebugInfo = false;
  };

  # GTK renders through Pango/Cairo; its separate Xft renderer is unused.
  pango =
    (pkgs.pango.override {
      inherit cairo;
      x11Support = false;
      withIntrospection = false;
    }).overrideAttrs
      {
        pname = "desktop-pango";
        separateDebugInfo = false;
        postFixup = "";
      };
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
        "-Dx-locale-root=/var/empty"
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
