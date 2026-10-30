{
  pkgs ?
    let
      lock = builtins.fromJSON (builtins.readFile ./flake.lock);
      nixpkgs = lock.nodes.nixpkgs.locked;
    in
    import (builtins.fetchTarball {
      url = "https://github.com/${nixpkgs.owner}/${nixpkgs.repo}/archive/${nixpkgs.rev}.tar.gz";
      sha256 = nixpkgs.narHash;
    }) { },
}:
import ./desktop-zig.nix { inherit pkgs; }
