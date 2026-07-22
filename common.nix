pkgs: with pkgs; [
  superhtml
  (import ./neovim.nix pkgs)
  gopls
  jq
  lazygit
  lua-language-server
  nix-tree
  nix-update
  (python3Packages.fastavro.overridePythonAttrs (old: {
    dependencies = (old.dependencies or [ ]) ++ [ python3Packages.zstandard ];
  }))
  ffmpeg
  typescript-language-server
  awscli2
  claude-code
  gh
  go
  golangci-lint
  golangci-lint-langserver
  neovide
  nil
  nixfmt
  nixpkgs-review
  ripgrep
  tig
  zig
  zls
]
