{ pkgs }:
let
  # The desktop speaks PipeWire's native protocol itself. This trimmed client
  # library supplies the headers its ABI tests compare against, and backs the
  # independent libpipewire video consumer used by the portal fixture.
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
      # The fixture client uses only PipeWire's native socket; RTKit and portal
      # integration belong to the system daemon.
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
      # The default client config loads these modules for the fixture's video
      # stream. Server factories and filters run in the system PipeWire daemon.
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
