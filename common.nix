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
  antigravity-cli
  awscli2
  claude-code
  codex
  gdu
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
  tuicr
  zig
  zls
]
