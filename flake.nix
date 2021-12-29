{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  inputs.awsebcli.url = "github:kirillrdy/nixpkgs/awsebcli";
  outputs = { self, nixpkgs, awsebcli }:
    {
      nixosConfigurations =
        let
          simplesystem = hostName: enableNvidia: {
            system = "x86_64-linux";
            modules = [
              ({ pkgs, lib, ... }:
                import ./common.nix { inherit pkgs lib awsebcli hostName enableNvidia; })
            ];
          };
        in
        {
          osaka = nixpkgs.lib.nixosSystem (simplesystem "osaka" false);
          shinseikai = nixpkgs.lib.nixosSystem (simplesystem "shinseikai" true);
        };
    };
}
