{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs =
    { self, nixpkgs }:
    {
      packages.x86_64-linux.neovim = import ./neovim.nix (import nixpkgs { system = "x86_64-linux"; });
      packages.x86_64-darwin.neovim = import ./neovim.nix (import nixpkgs { system = "x86_64-darwin"; });
      nixosConfigurations = {
        # amd ryzen 5
        #shinseikai = nixpkgs.lib.nixosSystem (simplesystem { hostName = "shinseikai"; enableNvidia = true; });
        # legacy, yao: T460s

        # Lenovo X1 gen9, alderlake
        osaka = nixpkgs.lib.nixosSystem (
          import ./nixos.nix {
            hostName = "osaka";
          }
        );
	# Lenovo X1 gen13, ....
        hagi = nixpkgs.lib.nixosSystem (
          import ./nixos.nix {
            hostName = "hagi";
          }
        );

        # i7-13700K, raptorlake
        tsutenkaku = nixpkgs.lib.nixosSystem (
          import ./nixos.nix {
            hostName = "tsutenkaku";
            enableNvidia = true;
          }
        );
      };
    };
}
