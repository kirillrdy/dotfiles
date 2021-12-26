{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }: {
    nixosConfigurations.osaka = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./osaka.nix
      ];
    };
    nixosConfigurations.shinseikai = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./hardware-configuration-shinseikai.nix
        ./shinseikai.nix
      ];
    };
  };
}
