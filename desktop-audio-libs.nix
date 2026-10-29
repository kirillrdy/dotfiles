{
  pkgs,
  dbus ? pkgs.dbus,
}:
let
  # This process is a control client. Hardware, codecs, and session policy run
  # in the system's normal PipeWire/WirePlumber services, not in these libraries.
  pipewire = pkgs.pipewire.overrideAttrs {
    pname = "desktop-pipewire-client";
    outputs = [
      "out"
      "dev"
    ];
    separateDebugInfo = false;
    nativeBuildInputs = with pkgs; [
      meson
      ninja
      pkg-config
      python3
    ];
    buildInputs = [ dbus ];
    mesonFlags = [
      "-Dauto_features=disabled"
      "-Dexamples=disabled"
      "-Dtests=enabled"
      "-Dpipewire-jack=disabled"
      "-Dpipewire-v4l2=disabled"
      "-Dflatpak=disabled"
      "-Ddbus=enabled"
      "-Dsession-managers=[]"
      "-Drlimits-install=false"
    ];
    doInstallCheck = false;
    postInstall = ''
      rm -rf "$out/bin"
    '';
  };

in
{
  inherit pipewire;
}
