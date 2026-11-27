final: prev:
{
  # Pin antigravity-cli to the latest upstream release until nixpkgs catches up.
  antigravity-cli = prev.antigravity-cli.overrideAttrs (old: rec {
    version = "1.5.19";
    src =
      let
        fetch =
          path: hash:
          prev.fetchurl {
            url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-6272854199762944/${path}";
            inherit hash;
          };
      in
      {
        x86_64-linux = fetch "linux-x64/cli_linux_x64.tar.gz" "sha512-oATwztf/Ej/B3+l0DpS2h/H+PWzc9oZEbSaBeRyZB8iv4uDQ3eICKdZexctba0zahHeulCBe08AhJXOECQiOCA==";
        aarch64-linux = fetch "linux-arm/cli_linux_arm64.tar.gz" "sha512-oCtrC2tj9ULBma5qklLZFrn8MT4vduCayqcv+twrnMgJfZ7adMqq6YMEqQ+ib6FjG+jYrKLWkTgnUsgzY55kNQ==";
        aarch64-darwin = fetch "darwin-arm/cli_mac_arm64.tar.gz" "sha512-oh2y5bdyT9HPMbhcB8zVwuoe+HKJgPR0BB40U7n0FcwZBH8SvTWyi3MPBeGDxNAPvEB+OVeGd9UXbkny5soSuw==";
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
