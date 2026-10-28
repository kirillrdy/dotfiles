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

  wireplumber =
    (pkgs.wireplumber.override {
      inherit pipewire;
      enableDocs = false;
      enableGI = false;
    }).overrideAttrs
      {
        pname = "desktop-wireplumber-client";
        buildInputs = [
          pkgs.glib
          pipewire
        ];
        mesonFlags = [
          "-Dauto_features=disabled"
          "-Ddoc=disabled"
          "-Dintrospection=disabled"
          "-Dmodules=false"
          "-Ddaemon=false"
          "-Dtools=false"
          "-Dtests=false"
          "-Dsystemd-system-service=false"
          "-Dsystemd-user-service=false"
          "-Dsysconfdir=/etc"
        ];
      };

in
{
  inherit pipewire wireplumber;
}
