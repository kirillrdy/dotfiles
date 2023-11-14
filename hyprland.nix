pkgs: pkgs.writeShellScriptBin "hello" ''
  ${pkgs.hyprland}/bin/Hyprland -c ${./hyprland.conf} $@
''
