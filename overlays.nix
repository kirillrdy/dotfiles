final: prev:
{
  # Pin antigravity-cli to the latest upstream release until nixpkgs catches up.
  antigravity-cli = prev.antigravity-cli.overrideAttrs (old: rec {
    version = "1.5.17";
    src =
      let
        fetch =
          path: hash:
          prev.fetchurl {
            url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-4823843970351104/${path}";
            inherit hash;
          };
      in
      {
        x86_64-linux = fetch "linux-x64/cli_linux_x64.tar.gz" "sha512-calnqhbgq12HGWvNZ3ITC9q1Wy/XaM0k0hsdpAH/n2AoC5dsrT3BSi1kYjOw6vjK+HxJDu1zBE1UVQy7PY1n0g==";
        aarch64-linux = fetch "linux-arm/cli_linux_arm64.tar.gz" "sha512-5PCG0HMLMlz9Q46pA5bueOsjoxEO9/eSgkyIF7jQQyRit7X5Gz2TP8GTKm9Lpz3lBeLpb0REjJ+yQnKS6tcW9w==";
        aarch64-darwin = fetch "darwin-arm/cli_mac_arm64.tar.gz" "sha512-IJ5tLpOPLC65CNbU/9ahMKBYsy6XqhbPTn4pzAzToIhnxq9FIr1B63YqflBe7kGECaiIfCzi0k2KvWbiRra5cg==";
      }
      .${prev.stdenv.hostPlatform.system};
  });
}
// prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
  stats = prev.stats.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace Modules/Disk/main.swift \
        --replace-fail 'case "total": replacement = DiskSize(d.size).getReadableMemory()' \
                       'case "total": replacement = String(format: "%.0f GB", DiskSize(d.size).gigabytes)' \
        --replace-fail 'case "used": replacement = DiskSize(d.size - d.free).getReadableMemory()' \
                       'case "used": replacement = String(format: self.textValue.contains("$capacity.total") ? "%.0f" : "%.0f GB", DiskSize(d.size - d.free).gigabytes)' \
        --replace-fail 'case "free": replacement = DiskSize(d.free).getReadableMemory()' \
                       'case "free": replacement = String(format: self.textValue.contains("$capacity.total") ? "%.0f" : "%.0f GB", DiskSize(d.free).gigabytes)'
    '';
  });
}
