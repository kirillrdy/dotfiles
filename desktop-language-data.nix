{ pkgs }:
# GTK's language-names.c reads these two legacy XML tables and binds their
# translation domains. Keep every locale, without unrelated country, currency,
# subdivision, or script databases. Dereference aliases to avoid retaining the
# complete iso-codes output through symlinks.
pkgs.runCommand "desktop-language-data-${pkgs.isocodes.version}" { } ''
  mkdir -p "$out/share/xml/iso-codes" "$out/share/pkgconfig"
  for table in iso_639 iso_639_3; do
    cp -L "${pkgs.isocodes}/share/xml/iso-codes/$table.xml" "$out/share/xml/iso-codes/"
    for catalog in ${pkgs.isocodes}/share/locale/*/LC_MESSAGES/"$table.mo"; do
      locale=$(basename "$(dirname "$(dirname "$catalog")")")
      mkdir -p "$out/share/locale/$locale/LC_MESSAGES"
      cp -L "$catalog" "$out/share/locale/$locale/LC_MESSAGES/$table.mo"
    done
  done
  cat > "$out/share/pkgconfig/iso-codes.pc" <<EOF
  prefix=$out
  Name: iso-codes
  Description: Language names and translations used by the desktop toolkit
  Version: ${pkgs.isocodes.version}
  EOF
''
