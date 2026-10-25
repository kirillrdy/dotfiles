{
  description = "my computers in flakes";
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs";
    darwin.url = "github:nix-darwin/nix-darwin";
    darwin.inputs.nixpkgs.follows = "nixpkgs";
  };
  outputs =
    {
      nixpkgs,
      darwin,
      ...
    }:
    let
      inherit (nixpkgs) lib;
      pkgs = nixpkgs.legacyPackages.x86_64-linux;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      mkSystem =
        hostName:
        {
          enableNvidia ? false,
          enableOpencl ? false,
          enableOpenvino ? false,
          enableLightDesktop ? false,
        }:
        lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = {
            inherit
              hostName
              enableNvidia
              enableOpencl
              enableOpenvino
              enableLightDesktop
              ;
          };
          modules = [ ./nixos.nix ];
        };
    in
    {
      packages = lib.genAttrs systems (
        system:
        {
          neovim = import ./neovim.nix nixpkgs.legacyPackages.${system};
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          update = pkgs.writeShellApplication {
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

              git add -- flake.lock
              git commit -m "flake.lock: update inputs" -m "$(cat "$work_dir/diff")" --only -- flake.lock
            '';
          };

          iso =
            (lib.nixosSystem {
              system = "x86_64-linux";
              modules = [
                "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-gnome.nix"
                {
                  environment.systemPackages = [
                    (pkgs.writers.writeGoBin "nixos-installer" { } ./nixos-installer.go)
                  ];
                }
              ];
            }).config.system.build.isoImage;
        }
      );

      darwinConfigurations."shirahama" = darwin.lib.darwinSystem {
        modules = [
          ./darwin.nix
          "${nixpkgs}/nixos/modules/programs/git.nix"
        ];
      };

      nixosConfigurations = builtins.mapAttrs mkSystem {
        # Lenovo X1 gen9, alderlake
        osaka = { };
        # Lenovo X1 gen13, lunarlake
        hagi = {
          enableOpenvino = true;
          enableLightDesktop = true;
        };
        # i7-13700K, raptorlake
        tsutenkaku = {
          enableNvidia = true;
          enableOpencl = true;
        };
      };
    };
}
