pkgs:
pkgs.wrapNeovim pkgs.neovim-unwrapped {
  configure = {
    customRC = ''
      lua << EOF
      ${builtins.readFile ./init.lua}
      EOF
      let g:rooter_patterns = ['.git']
    '';
    packages.myVimPackage = with pkgs.vimPlugins; {
      start = [
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
    };
  };
}
