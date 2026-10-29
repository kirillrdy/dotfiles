{ pkgs }:
# NixOS selects the lock's PAM modules through absolute paths in /etc/pam.d.
# Keep the client ABI and audit support, without optional userdb/logind modules
# pulling Berkeley DB and systemd into the desktop executable's own closure.
(pkgs.pam.override { withLogind = false; }).overrideAttrs (old: {
  pname = "desktop-pam-client";
  buildInputs = pkgs.lib.remove pkgs.db4 old.buildInputs;
  mesonFlags = old.mesonFlags ++ [ "-Dpam_userdb=disabled" ];
  outputChecks.out.disallowedRequisites = old.outputChecks.out.disallowedRequisites ++ [
    pkgs.db4
    pkgs.systemdLibs
  ];
})
