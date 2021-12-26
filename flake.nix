{
  description = "A very basic flake";

  inputs.nixpkgs.url = "github:nixos/nixpkgs";

  outputs = { self, nixpkgs }: {

    packages.x86_64-linux.hello = nixpkgs.legacyPackages.x86_64-linux.hello;

    defaultPackage.x86_64-linux = self.packages.x86_64-linux.hello;

    nixosConfigurations.osaka = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [ ./osaka.nix ];
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
