{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }:
    let
      shinseikai = { config, pkgs, lib, ... }:
        import ./common.nix {
          inherit config pkgs lib;
          hostName = "shinseikai";
          enableNvidia = true;
        };
      osaka = { config, pkgs, lib, ... }:
        import ./common.nix {
          inherit config pkgs lib;
          hostName = "osaka";
        };
    in
    {
      nixosConfigurations.osaka = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ osaka ];
      };
      nixosConfigurations.shinseikai = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [ shinseikai ];
      };
    };
}
