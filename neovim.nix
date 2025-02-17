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
        nord-nvim
        kanagawa-nvim
        (nvim-treesitter.withPlugins (
          p: with p; [
            go
            just
            kdl
            c
            cpp
            nix
            python
            ruby
            sql
            terraform
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
        templ-vim
      ];
    };
  };
}
