final: prev:
let
  version = "1.5.9";
  buildId = "4515810895593472";
  wholeVersion = "${version}-${buildId}";
  sources = {
    x86_64-linux = {
      url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${wholeVersion}/linux-x64/cli_linux_x64.tar.gz";
      hash = "sha256-ix9eVnefJDSgrzbxtxWoOSoITeVQ+MaLx5gh+V+r8/o=";
    };
    aarch64-linux = {
      url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${wholeVersion}/linux-arm/cli_linux_arm64.tar.gz";
      hash = "sha256-OhjCOMfuZmHkPffoJKfUwb7Xiu7aCUMJIaDx2/6CW8o=";
    };
    aarch64-darwin = {
      url = "https://storage.googleapis.com/antigravity-public/antigravity-cli/${wholeVersion}/darwin-arm/cli_mac_arm64.tar.gz";
      hash = "sha256-UfuOt+GMU9RmXwBDt2HwT00NSy6wRrrGwty+Mkc7Wy4=";
    };
  };
  system = prev.stdenv.hostPlatform.system;
  source = sources.${system} or (throw "Unsupported system: ${system}");
in
{
  antigravity-cli = prev.antigravity-cli.overrideAttrs (old: {
    inherit version;
    src = prev.fetchurl source;
    passthru = (old.passthru or { }) // {
      inherit wholeVersion;
    };
  });
}
