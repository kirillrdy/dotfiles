pkgs:
pkgs.wrapNeovimUnstable pkgs.neovim-unwrapped {
  luaRcContent = ''
    ${builtins.readFile ./init.lua}
    -- let g:rooter_patterns = ['.git']
  '';
  plugins = with pkgs.vimPlugins; [
    telescope-nvim
    plenary-nvim
    vim-rooter
    kanagawa-nvim
    (nvim-treesitter.withPlugins (
      p: with p; [
        c
        cpp
        go
        javascript
        just
        nix
        python
        ruby
        sql
        terraform
        typescript
        zig
      ]
    ))
    vim-fugitive
    nvim-lspconfig
    nvim-cmp
    cmp-buffer
    cmp-path
    cmp-nvim-lsp
    cmp-nvim-lua
    nerdtree
  ];
}
