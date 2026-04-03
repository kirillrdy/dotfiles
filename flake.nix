{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs =
    { self, nixpkgs }:
    let
      mkSystem =
        {
          hostName,
          enableNvidia ? false,
        }:
        nixpkgs.lib.nixosSystem {
          system = "x86_64-linux";
          specialArgs = { inherit hostName enableNvidia; };
          modules = [ ./nixos.nix ];
        };
    in
    {
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
      nixosConfigurations = {
        # amd ryzen 5
        #shinseikai = mkSystem { hostName = "shinseikai"; enableNvidia = true; };
        # legacy, yao: T460s

        # Lenovo X1 gen9, alderlake
        osaka = mkSystem { hostName = "osaka"; };
        # Lenovo X1 gen13, lunarlake
        hagi = mkSystem { hostName = "hagi"; };

        # i7-13700K, raptorlake
        tsutenkaku = mkSystem {
          hostName = "tsutenkaku";
          enableNvidia = true;
        };
      };
    };
}
