{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  outputs = { self, nixpkgs }:
    {
      packages.x86_64-linux.neovim = import ./neovim.nix (import nixpkgs { system = "x86_64-linux"; });
      nixosConfigurations =
        let
          simplesystem = import ./nixos.nix;
        in
        {
          # old work machine Retired 20-10-2022
          #tsuruhashi = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsuruhashi"; rootPool = "tsuruhashi/root"; bootDevice = "/dev/sda3"; swapDevice = "/dev/sda2"; });
          # amd ryzen 5
          #shinseikai = nixpkgs.lib.nixosSystem (simplesystem { hostName = "shinseikai"; enableNvidia = true; });
          # legacy, yao: T460s

          # Lenovo X1 gen9
          osaka = nixpkgs.lib.nixosSystem (simplesystem { hostName = "osaka"; buildJobs = 1; });
          tsutenkaku = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsutenkaku"; enableNvidia = true; buildJobs = 3; });
        };
    };
}
