{
  description = "my computers in flakes";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    darwin.url = "github:nix-darwin/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs =
    {
      self,
      nixpkgs,
      darwin,
    }:
    let
      mkSystem =
        {
          hostName,
          enableNvidia ? false,
          enableOpencl ? false,
          enableOpenvino ? false,
        }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit
              hostName
              enableNvidia
              enableOpencl
              enableOpenvino
              ;
          };
          modules = [ ./nixos.nix ];
        };
    in
    {
      apps.x86_64-linux.update = {
        type = "app";
        program = "${self.packages.x86_64-linux.update}/bin/update";
      };
      packages.x86_64-linux.update =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
        in
        pkgs.writeShellApplication {
          name = "update";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.git
            pkgs.nix
            pkgs.nvd
          ];
          text = ''
            if [[ $# -gt 2 ]]; then
              echo "Usage: nix run .#update -- [hostname [baseline-system-path]]" >&2
              exit 1
            fi

            host=''${1:-$(uname -n)}
            baseline=$(readlink -e "''${2:-/run/current-system}")
            cd "$(git rev-parse --show-toplevel)"

            if [[ -n $(git status --porcelain --untracked-files=no) ]]; then
              echo "Commit or stash existing changes before updating." >&2
              exit 1
            fi

            work_dir=$(mktemp -d)
            trap 'rm -rf "$work_dir"' EXIT

            nix flake update
            nix build ".#nixosConfigurations.\"''${host}\".config.system.build.toplevel" \
              --out-link "$work_dir/result"
            nvd diff "$baseline" "$(readlink -e "$work_dir/result")" | tee "$work_dir/diff"

            if git diff --quiet -- flake.lock; then
              echo "Flake inputs are already up to date; no commit needed."
              exit 0
            fi

            {
              echo "flake.lock: update inputs"
              echo
              cat "$work_dir/diff"
            } > "$work_dir/commit-message"
            git add -- flake.lock
            git commit -F "$work_dir/commit-message" --only -- flake.lock
          '';
        };

      packages.x86_64-linux.iso =
        let
          pkgs = import nixpkgs { system = "x86_64-linux"; };
          nixos-installer = pkgs.runCommand "nixos-installer" { nativeBuildInputs = [ pkgs.go ]; } ''
            mkdir -p $out/bin
            cp ${./nixos-installer.go} main.go
            env HOME=$(mktemp -d) go build -o $out/bin/nixos-installer main.go
          '';
        in
        (nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          modules = [
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-gnome.nix"
            { environment.systemPackages = [ nixos-installer ]; }
          ];
        }).config.system.build.isoImage;
      packages.x86_64-linux.neovim = import ./neovim.nix (import nixpkgs { system = "x86_64-linux"; });
      packages.aarch64-linux.neovim = import ./neovim.nix (import nixpkgs { system = "aarch64-linux"; });
      packages.x86_64-darwin.neovim = import ./neovim.nix (import nixpkgs { system = "x86_64-darwin"; });
      packages.aarch64-darwin.neovim = import ./neovim.nix (
        import nixpkgs { system = "aarch64-darwin"; }
      );

      darwinConfigurations."shirahama" = darwin.lib.darwinSystem {
        modules = [
          ./darwin.nix
          "${nixpkgs}/nixos/modules/programs/git.nix"
        ];
        specialArgs = { inherit self; };
      };

      nixosConfigurations = {
        # amd ryzen 5
        #shinseikai = mkSystem { hostName = "shinseikai"; enableNvidia = true; };
        # legacy, yao: T460s

        # Lenovo X1 gen9, alderlake
        osaka = mkSystem { hostName = "osaka"; };
        # Lenovo X1 gen13, lunarlake
        hagi = mkSystem {
          hostName = "hagi";
          enableOpenvino = true;
        };

        # i7-13700K, raptorlake
        tsutenkaku = mkSystem {
          hostName = "tsutenkaku";
          enableNvidia = true;
          enableOpencl = true;
        };
      };
    };
}
