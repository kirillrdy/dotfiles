pkgs: with pkgs; [
  (import ./neovim.nix pkgs)
  (python3Packages.fastavro.overridePythonAttrs (old: {
    dependencies = (old.dependencies or [ ]) ++ [ python3Packages.zstandard ];
  }))
  antigravity-cli
  awscli2
  codex
  ffmpeg
  gdu
  gh
  go
  golangci-lint
  golangci-lint-langserver
  gopls
  jq
  lazygit
  lua-language-server
  neovide
  nil
  nix-tree
  nix-update
  nixfmt
  nixpkgs-review
  nvd
  ripgrep
  tig
  tuicr
  zig_0_17
  zls
]
