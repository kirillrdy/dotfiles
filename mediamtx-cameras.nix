{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.services.mediamtxCameras;

  mkCamera = name: channels: { inherit name channels; };
  mkChannel = name: width: height: fps: {
    inherit
      name
      width
      height
      fps
      ;
  };

  roofChannels = [
    (mkChannel "ch1" 1280 960 1)
    (mkChannel "ch2" 1280 720 4)
  ];

  floorChannels = [
    (mkChannel "ch1" 3840 2160 1)
    (mkChannel "ch2" 1280 720 4)
  ];

  mkZone = shedName: zoneIdx: [
    (mkCamera "${shedName}/zone${toString zoneIdx}/roof" roofChannels)
    (mkCamera "${shedName}/zone${toString zoneIdx}/floor" floorChannels)
  ];

  mkShed =
    shedIdx:
    let
      shedName = "shed${toString shedIdx}";
    in
    lib.concatMap (mkZone shedName) (lib.range 1 4);

  defaultCameras = lib.concatMap mkShed (lib.range 1 6);

  allChannelPairs = lib.concatMap (
    cam:
    map (ch: {
      camName = cam.name;
      inherit ch;
    }) cam.channels
  ) cfg.cameras;

  # H.264 level 4.0 caps at ~2048x1088; anything larger needs 5.1
  h264Level = ch: if ch.width * ch.height > 2048 * 1088 then "5.1" else "4.0";

  simulatorPort = 8555;

  # ffmpeg pushes to the simulator; main mediamtx pulls from it
  mkFfmpegCmd =
    { camName, ch }:
    "${pkgs.ffmpeg}/bin/ffmpeg ${
      lib.escapeShellArgs [
        "-re"
        "-f"
        "lavfi"
        "-i"
        "testsrc2=size=${toString ch.width}x${toString ch.height}:rate=${toString ch.fps}"
        "-vf"
        "drawtext=text=%{localtime}:fontcolor=white:fontsize=100:x=(w-text_w)/2:y=(h-text_h)/2"
        "-c:v"
        "libx264"
        "-profile:v"
        "baseline"
        "-level"
        (h264Level ch)
        "-preset"
        "ultrafast"
        "-tune"
        "zerolatency"
        "-g"
        (toString ch.fps)
        "-bf"
        "0"
        "-rtsp_transport"
        "tcp"
        "-f"
        "rtsp"
      ]
    } \"rtsp://localhost:${toString simulatorPort}/${camName}/${ch.name}\"";

  ffmpegCmds = map mkFfmpegCmd allChannelPairs;

  ffmpegScript = pkgs.writeShellScript "ffmpeg-cameras" ''
    sleep 2
    ${lib.concatStringsSep " &\n" ffmpegCmds} &
    wait
  '';

  simulatorConfig = (pkgs.formats.yaml { }).generate "mediamtx-simulator.yaml" {
    rtspAddress = ":${toString simulatorPort}";
    rtspTransports = [ "tcp" ];
    rtmp = false;
    hls = false;
    webrtc = false;
    srt = false;
    api = false;
    metrics = false;
    pprof = false;
    paths.all = { };
  };

  # Main mediamtx pulls from the simulator, just like it would from real cameras
  cameraPaths = lib.listToAttrs (
    lib.concatMap (
      cam:
      map (
        ch:
        lib.nameValuePair "${cam.name}/${ch.name}" (
          {
            source = "rtsp://localhost:${toString simulatorPort}/${cam.name}/${ch.name}";
          }
          // lib.optionalAttrs (ch.name == "ch2") {
            record = false;
            sourceOnDemand = true;
          }
        )
      ) cam.channels
    ) cfg.cameras
  );
in
{
  options.services.mediamtxCameras = {
    cameras = lib.mkOption {
      type = lib.types.listOf lib.types.attrs;
      default = defaultCameras;
      description = "List of cameras created with mkCamera/mkChannel helpers.";
    };
    user = lib.mkOption {
      type = lib.types.str;
      default = "mediamtx";
      description = "User account under which mediamtx and ffmpeg-cameras run.";
    };
    group = lib.mkOption {
      type = lib.types.str;
      default = cfg.user;
      description = "Group under which mediamtx and ffmpeg-cameras run.";
    };
    storagePath = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mediamtx";
      description = "Directory where mediamtx stores recordings.";
    };
    passwordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Path to a file containing CAMERA_PASSWORD=... for simulator auth.";
    };
  };

  config = lib.mkIf (cfg.cameras != [ ]) {
    services.mediamtx.enable = true;
    services.mediamtx.package = pkgs.mediamtx.overrideAttrs (old: {
      patches = (old.patches or [ ]) ++ [
        # fix fmp4 playback seek position
        (pkgs.fetchpatch {
          name = "mediamtx-fmp4-seek.patch";
          url = "https://github.com/kirillrdy/mediamtx/commit/c2a86eb6a221174820af74c580e08d37fbd1120b.patch";
          hash = "sha256-PQit6PInKok+Qj0zP1pjlA4kkRpGZwyD0Eo5Q/wcA5A=";
        })
        # speed up seek into long fmp4 segments using byte-offset interpolation
        (pkgs.fetchpatch {
          name = "mediamtx-fmp4-interpolation.patch";
          url = "https://github.com/kirillrdy/mediamtx/commit/090c9c3d670e621eb7449c373da55dfbbcf3e04f.patch";
          hash = "sha256-clii+un/F1/cB6I2oA5jkNIROimQjm3QEqxd+TabvmA=";
        })
        # fix pre-roll frames having wrong DTS and zero duration in fmp4 playback
        (pkgs.fetchpatch {
          name = "mediamtx-fmp4-preroll-dts.patch";
          url = "https://github.com/kirillrdy/mediamtx/commit/c2308b771e8c3e092f78092b70867ad5a420870e.patch";
          hash = "sha256-AZw4cwqQIScDSPTfSBg+plI8AVpH379FwLvWdUIRYS0=";
        })
      ];
    });
    services.mediamtx.env = {
      TZ = "UTC";
    };
    services.mediamtx.settings = {
      authInternalUsers = lib.mkIf (cfg.passwordFile != null) [
        {
          user = "camera";
          pass = "$ENV{CAMERA_PASSWORD}";
          permissions = [
            { action = "read"; path = ""; }
          ];
        }
      ];
      playback = true;
      playbackAddress = ":9996";
      pathDefaults = {
        record = true;
        recordPath = "${cfg.storagePath}/%path/%Y-%m-%d_%H-%M-%S_%f";
        recordFormat = "fmp4";
        recordDeleteAfter = "30d";
      };
      paths = {
        all = { };
      }
      // cameraPaths;
    };

    systemd.services.mediamtx.serviceConfig = {
      DynamicUser = lib.mkForce false;
      User = lib.mkForce cfg.user;
      Group = lib.mkForce cfg.group;
      StateDirectory = "mediamtx";
      StateDirectoryMode = "0755";
      UMask = "0022";
      ReadWritePaths = [ "${cfg.storagePath}" ];
    } // lib.optionalAttrs (cfg.passwordFile != null) {
      EnvironmentFile = cfg.passwordFile;
    };

    systemd.services.mediamtx-simulator = {
      description = "MediaMTX camera simulator (RTSP server for fake streams)";
      after = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${config.services.mediamtx.package}/bin/mediamtx ${simulatorConfig}";
        User = cfg.user;
        Group = cfg.group;
        Restart = "always";
      };
    };

    systemd.services.ffmpeg-cameras = {
      description = "Push streams to MediaMTX simulator";
      after = [ "mediamtx-simulator.service" ];
      requires = [ "mediamtx-simulator.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = ffmpegScript;
        Restart = "always";
        User = cfg.user;
        SupplementaryGroups = [
          "video"
          "render"
        ];
      };
    };

    users.users.mediamtx = lib.mkIf (cfg.user == "mediamtx" && cfg.group == "mediamtx") {
      isSystemUser = true;
      group = "mediamtx";
    };
    users.groups.mediamtx = lib.mkIf (cfg.user == "mediamtx" && cfg.group == "mediamtx") { };
  };
}
