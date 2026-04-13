{ pkgs, self, ... }: {
  # List packages installed in system profile. To search by name, run:
  # $ nix-env -qaP | grep wget
  environment.systemPackages = with pkgs;[
    vim
    git
    firefox-bin
    gemini-cli
    ghostty-bin
    nixpkgs-review
    colima
    docker
    stats
    slack
    tig
    nil
    neovide
    self.packages.${pkgs.system}.neovim
  ];

  # nix-darwin now manages nix-daemon unconditionally when nix.enable is on.
  nix.enable = true;
  nix.settings.experimental-features = "nix-command flakes";
  nix.settings.sandbox = "relaxed";
  nix.settings.trusted-users = [ "root" "kirillvr" ];

  # Create /etc/zshrc that loads the nix-darwin environment.

  environment.variables = {
    EDITOR = "nvim";
    NEOVIDE_FORK = "1";
    GIT_CONFIG_SYSTEM = "/etc/gitconfig";
  };

  environment.etc."gitconfig".text = ''
    [user]
      name = Kirill Radzikhovskyy
      email = kirillrdy@gmail.com
  '';

  programs.bash.enable = true;
  programs.bash.interactiveShellInit = ''PS1='\[\e[32m\]\u@\h:\w> \[\e[0m\]' '';

  # Set system-wide settings
  system.primaryUser = "kirillvr";
  ids.gids.nixbld = 350;
  system.defaults = {
    dock.autohide = true;
    finder.AppleShowAllExtensions = true;
    NSGlobalDomain.AppleShowAllExtensions = true;
  };

  fonts.packages = [ pkgs.nerd-fonts.jetbrains-mono ];

  # Used for backwards compatibility, please read the changelog before changing.
  # $ darwin-rebuild changelog
  system.stateVersion = 4;

  # The platform the configuration will be used on.
  nixpkgs.hostPlatform = "aarch64-darwin";
  nixpkgs.config.allowUnfree = true;
}
