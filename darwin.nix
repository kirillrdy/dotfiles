{ pkgs, ... }:
{
  environment.systemPackages =
    (import ./common.nix pkgs)
    ++ (with pkgs; [
      stats
      btop
    ]);

  networking.hostName = "shirahama";

  nix.settings = {
    experimental-features = "nix-command flakes";
    sandbox = "relaxed";
    trusted-users = [ "kirillvr" ];
  };

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

  programs.bash.completion.enable = true;
  programs.bash.interactiveShellInit = ''PS1='\[\e[32m\]\u@\h:\w> \[\e[0m\]' '';
  environment.shells = [ pkgs.bash ];

  # Set system-wide settings
  system.primaryUser = "kirillvr";
  users.users.kirillvr.shell = pkgs.bash;
  security.pam.services.sudo_local.touchIdAuth = true;
  system.defaults = {
    dock.autohide = true;
    NSGlobalDomain.AppleShowAllExtensions = true;
  };

  system.activationScripts.postActivation.text = ''
    /usr/bin/pmset -c sleep 0
    /usr/bin/dscl . -create /Users/kirillvr UserShell /run/current-system/sw/bin/bash
    install -d -o kirillvr -g staff "/Users/kirillvr/Library/Application Support/com.mitchellh.ghostty"
    install -m 644 -o kirillvr -g staff ${pkgs.writeText "config.ghostty" ''
      font-size = 16
    ''} "/Users/kirillvr/Library/Application Support/com.mitchellh.ghostty/config.ghostty"
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
  system.stateVersion = 5;

  # The platform the configuration will be used on.
  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = [ (import ./overlays.nix) ];
}
