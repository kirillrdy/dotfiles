final: prev:
prev.lib.optionalAttrs prev.stdenv.hostPlatform.isDarwin {
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
