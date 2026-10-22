pkgs:
pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
  luaRcContent = builtins.readFile ./init.lua;
  plugins = with pkgs.vimPlugins; [
    vim-fugitive
    telescope-nvim
    plenary-nvim
    kanagawa-nvim
    (nvim-treesitter.withPlugins (
      p: with p; [
        c
        cpp
        go
        javascript
        just
        nix
        lua
        python
        ruby
        sql
        terraform
        typescript
        zig
      ]
    ))
    nvim-lspconfig
    nvim-cmp
    cmp-buffer
    cmp-path
    cmp-nvim-lsp
  ];
}
