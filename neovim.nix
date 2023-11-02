pkgs: pkgs.wrapNeovim pkgs.neovim-unwrapped {
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
        rose-pine
        tokyonight-nvim
        nvim-treesitter.withAllGrammars
        vim-fugitive
        nvim-lspconfig
        nvim-cmp
        cmp-buffer
        cmp-path
        cmp-nvim-lsp
        cmp-nvim-lua
        nerdtree
        (pkgs.vimUtils.buildVimPlugin {
          pname = "templ.vim";
          version = "2023-10-23";
          src = pkgs.fetchFromGitHub {
            owner = "joerdav";
            repo = "templ.vim";
            rev = "5cc48b93a4538adca0003c4bc27af844bb16ba24";
            hash = "sha256-YdV8ioQJ10/HEtKQy1lHB4Tg9GNKkB0ME8CV/+hlgYs=";
          };
          meta.homepage = "https://github.com/joerdav/templ.vim";
        })
      ];
    };
  };
}
