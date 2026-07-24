{ pkgs, self, ... }:
let
  vfkit-builder = import ./vfkit-builder.nix { inherit (pkgs) system; };
in
{
  environment.systemPackages =
    (import ./common.nix pkgs)
    ++ [ vfkit-builder ]
    ++ (with pkgs; [
      stats
      btop
    ]);

  nix.enable = true;
  nix.settings.experimental-features = "nix-command flakes";
  nix.settings.sandbox = "relaxed";
  nix.settings.trusted-users = [
    "root"
    "kirillvr"
  ];

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
