{
  description = "my computers in flakes";
  inputs.nixpkgs.url = "github:nixos/nixpkgs";
  inputs.awsebcli.url = "github:kirillrdy/nixpkgs/awsebcli";
  outputs = { self, nixpkgs, awsebcli }:
    let
      shinseikai = { config, pkgs, lib, ... }:
        import ./common.nix {
          inherit config pkgs lib awsebcli;
          hostName = "shinseikai";
          enableNvidia = true;
        };
      osaka = { config, pkgs, lib, ... }:
        import ./common.nix {
          inherit config pkgs lib awsebcli;
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
