final: prev:
{
  # Pin antigravity-cli to the latest upstream release until nixpkgs catches up.
  antigravity-cli = prev.antigravity-cli.overrideAttrs (old: rec {
    version = "1.5.18";
    src =
      let
        fetch =
          path: hash:
          prev.fetchurl {
            url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${version}-6386224290725888/${path}";
            inherit hash;
          };
      in
      {
        x86_64-linux = fetch "linux-x64/cli_linux_x64.tar.gz" "sha512-7zeeyGlxkRL2lujHz933dmGHEuWPw45T34CAHWUoq7Rnd4LHyHePnAnJEj+kTCwyZ10ijAbyqPeo9CFOdfW7Jg==";
        aarch64-linux = fetch "linux-arm/cli_linux_arm64.tar.gz" "sha512-bFnLzlp2Mgg91O9ZQpblLOCr3BL4tOy1VSPgk3SM8Xj4+Dg9flHp7XhZ6m5GyDpDp7RjZLDgM90Tr7JNa/vkyA==";
        aarch64-darwin = fetch "darwin-arm/cli_mac_arm64.tar.gz" "sha512-0Q4ST1602pTrtsSUzS57OHRPn2bo6HFF0sutHL08QWD9iKec1CIN/OfJ2g3erWUjRrzIOZFFdfZEdDiujR1dzA==";
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
