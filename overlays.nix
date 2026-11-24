final: prev:
{
  # Pin codex to the latest upstream release until nixpkgs catches up.
  codex = prev.codex.overrideAttrs (old: rec {
    version = "0.172.0";
    buildCommit = "3d86e43b075adeba2193ec5c22ac92f55afd82e6";
    src = prev.fetchFromGitHub {
      owner = "openai";
      repo = "codex";
      rev = buildCommit;
      hash = "sha256-MDLBCNRb/1DNPZWegnF2yFDQU4IdSsgQcYOh0JV3EN8=";
    };
    cargoHash = "sha256-baArx7G/DmmT+1k4ykHoBnVU73ta0F+Hai4hWBkHV/Q=";
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
