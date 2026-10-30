{ pkgs }:
let
  # The desktop controls audio and produces raw screen video. Hardware, codecs,
  # and session policy run in the system's normal PipeWire/WirePlumber services.
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
    buildInputs = [ ];
    mesonFlags = [
      "-Dauto_features=disabled"
      "-Dexamples=disabled"
      "-Dtests=enabled"
      "-Dpipewire-jack=disabled"
      "-Dpipewire-v4l2=disabled"
      "-Dflatpak=disabled"
      # GIO handles the shell's D-Bus calls. This audio client uses PipeWire's
      # native socket; RTKit and portal integration belong to the system daemon.
      "-Ddbus=disabled"
      "-Daudiotestsrc=disabled"
      # pw_stream uses the SPA video adapter even for matching raw formats.
      "-Dvideoconvert=enabled"
      "-Dvideotestsrc=disabled"
      "-Dsession-managers=[]"
      "-Drlimits-install=false"
    ];
    doInstallCheck = false;
    postInstall = ''
      rm -rf "$out/bin"
      # The default client config uses these modules for native controls and
      # PCM event playback and raw screen video. Server factories and filters
      # run in the system PipeWire daemon rather than in the desktop process.
      for module in "$out"/lib/pipewire-0.3/libpipewire-module-*.so; do
        case "$(basename "$module")" in
          libpipewire-module-protocol-native.so|libpipewire-module-client-node.so|\
          libpipewire-module-client-device.so|libpipewire-module-adapter.so|\
          libpipewire-module-metadata.so|libpipewire-module-session-manager.so|\
          libpipewire-module-rt.so) ;;
          *) rm "$module" ;;
        esac
      done
      rm -rf "$out/lib/spa-0.2/aec" "$out/lib/spa-0.2/audiomixer" \
        "$out/lib/spa-0.2/control" "$out/lib/spa-0.2/filter-graph"
    '';
  };

in
{
  inherit pipewire;
}
