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
      (old: {
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
        # The upstream library-only build omits every module. Add precisely the
        # two upstream C modules loaded by desktop-audio.zig, without Lua or policy.
        postPatch = (old.postPatch or "") + ''
          cat >> meson.build <<'EOF'
          foreach module : ['default-nodes-api', 'mixer-api']
            shared_library('wireplumber-module-' + module,
              'modules/module-' + module + '.c',
              install: true,
              install_dir: wireplumber_module_dir,
              dependencies: [wp_dep, pipewire_dep, mathlib])
          endforeach
          EOF
        '';
      });

in
{
  inherit pipewire wireplumber;
}
