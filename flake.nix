{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs/master";
  outputs =
    { self, nixpkgs }:
    {
      packages.x86_64-linux.neovim = import ./neovim.nix (import nixpkgs { system = "x86_64-linux"; });
      packages.x86_64-darwin.neovim = import ./neovim.nix (import nixpkgs { system = "x86_64-darwin"; });
      nixosConfigurations = {
        # old work machine Retired 20-10-2022
        #tsuruhashi = nixpkgs.lib.nixosSystem (simplesystem { hostName = "tsuruhashi"; rootPool = "tsuruhashi/root"; bootDevice = "/dev/sda3"; swapDevice = "/dev/sda2"; });
        # amd ryzen 5
        #shinseikai = nixpkgs.lib.nixosSystem (simplesystem { hostName = "shinseikai"; enableNvidia = true; });
        # legacy, yao: T460s

        # Lenovo X1 gen9
        osaka = nixpkgs.lib.nixosSystem (
          import ./nixos.nix {
            hostName = "osaka";
            buildJobs = 1;
            #gccarch = "alderlake";
          }
        );
        tsutenkaku = nixpkgs.lib.nixosSystem (
          import ./nixos.nix {
            hostName = "tsutenkaku";
            enableNvidia = true;
            buildJobs = 1;
            #gccarch = "raptorlake";
            #systemFeatures = [
            #  "gccarch-alderlake"
            #  "gccarch-raptorlake"
            #];
          }
        );
      };
    };
}
