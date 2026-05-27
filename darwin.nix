{ pkgs, self, ... }:
let
  claude-usage-systray = pkgs.stdenv.mkDerivation rec {
    pname = "claude-usage-systray";
    version = "1.0.4";
    src = pkgs.fetchFromGitHub {
      owner = "adntgv";
      repo = "claude-usage-systray";
      rev = "v${version}";
      sha256 = "11ynbadzjkmpxx2msaxfcklf821zcpn6gpf5j17xnjxmq8790grh";
    };
    nativeBuildInputs = [ pkgs.swiftPackages.swift ];
    buildPhase = ''
      runHook preBuild
      cd claude-usage-systray
      mkdir -p build
      swiftc -O -o build/ClaudeUsageSystray Sources/*.swift
      runHook postBuild
    '';
    installPhase = ''
      runHook preInstall
      APP="$out/Applications/ClaudeUsageSystray.app"
      mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
      cp build/ClaudeUsageSystray "$APP/Contents/MacOS/"
      substitute Resources/Info.plist "$APP/Contents/Info.plist" \
        --replace-fail '$(EXECUTABLE_NAME)' 'ClaudeUsageSystray' \
        --replace-fail '$(PRODUCT_BUNDLE_IDENTIFIER)' 'com.claude.usage-systray' \
        --replace-fail '$(MACOSX_DEPLOYMENT_TARGET)' '13.0'
      printf 'APPL????' > "$APP/Contents/PkgInfo"
      runHook postInstall
    '';
    meta.platforms = pkgs.lib.platforms.darwin;
  };
in
{
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages =
    (import ./common.nix pkgs)
    ++ (with pkgs; [
      stats
      btop
    ])
    ++ [ claude-usage-systray ];

  # nix-darwin now manages nix-daemon unconditionally when nix.enable is on.
  nix.enable = true;
  nix.settings.experimental-features = "nix-command flakes";
  nix.settings.sandbox = "relaxed";
  nix.settings.trusted-users = [
    "root"
    "kirillvr"
  ];
  nix.settings.extra-sandbox-paths = [ "/nix/var/cache/ccache" ];
  nix.linux-builder = {
    enable = false;
    systems = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    config = (
      { lib, ... }:
      {
        virtualisation = {
          cores = lib.mkForce 8;
          memorySize = lib.mkForce 8192;
          diskSize = lib.mkForce 40960;
        };
        boot.binfmt.emulatedSystems = [ "x86_64-linux" ];
      }
    );
  };

  # Create /etc/zshrc that loads the nix-darwin environment.

  environment.variables = {
    EDITOR = "nvim";
    NEOVIDE_FORK = "1";
    GIT_CONFIG_SYSTEM = "/etc/gitconfig";
  };

  programs.git.enable = true;
  programs.git.config = {
    user.name = "Kirill Radzikhovskyy";
    user.email = "kirillrdy@gmail.com";
  };

  programs.bash.enable = true;
  programs.bash.completion.enable = true;
  programs.bash.interactiveShellInit = ''PS1='\[\e[32m\]\u@\h:\w> \[\e[0m\]' '';

  # Set system-wide settings
  system.primaryUser = "kirillvr";
  users.users.kirillvr.shell = pkgs.bash;
  security.pam.services.sudo_local.touchIdAuth = true;
  ids.gids.nixbld = 350;
  system.defaults = {
    dock.autohide = true;
    finder.AppleShowAllExtensions = true;
    NSGlobalDomain.AppleShowAllExtensions = true;
  };

  system.activationScripts.pmset.text = ''
    /usr/bin/pmset -c sleep 0
  '';

  system.keyboard.enableKeyMapping = true;
  system.keyboard.userKeyMapping = [
    {
      HIDKeyboardModifierMappingSrc = 30064771129; # Caps Lock
      HIDKeyboardModifierMappingDst = -1; # Disable
    }
  ];

  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  # The platform the configuration will be used on.
  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;
}
