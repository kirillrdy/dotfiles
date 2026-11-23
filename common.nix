{ pkgs, ... }:
{
  environment.systemPackages = with pkgs; [
    (import ./neovim.nix pkgs)
    antigravity-cli
    awscli2
    claude-code
    codex
    ncdu
    gh
    jq
    neovide
    nil
    nix-tree
    nix-update
    nixfmt
    nixpkgs-review
    nvd
    ripgrep
    tig
    zig
    zls
  ];

  environment.variables = {
    EDITOR = "nvim";
    NEOVIDE_FORK = "1";
  };

  nix.settings.trusted-users = [ "kirillvr" ];
  nixpkgs.config.allowUnfree = true;
  nixpkgs.overlays = [ (import ./overlays.nix) ];

  programs.git = {
    enable = true;
    config = {
      user.name = "Kirill Radzikhovskyy";
      user.email = "kirillrdy@gmail.com";
    };
  };
}
