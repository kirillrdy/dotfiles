{ pkgs }:
# The desktop is an authentication agent. The system supplies polkitd and the
# privileged helper through /run/wrappers/bin, independently of these libraries.
(pkgs.polkit.override {
  withIntrospection = false;
  doCheck = false;
}).overrideAttrs
  {
    pname = "desktop-polkit-client";
    outputs = [
      "out"
      "dev"
    ];
    nativeBuildInputs = with pkgs; [
      glib
      pkg-config
      meson
      ninja
    ];
    buildInputs = with pkgs; [
      pam
      systemdLibs
    ];
    nativeCheckInputs = [ ];
    mesonFlags = [
      "-Dlibs-only=true"
      "-Dintrospection=false"
      "-Dgtk_doc=false"
      "-Dman=false"
      "-Dtests=false"
      "-Dgettext=false"
      "-Dsession_tracking=logind"
    ];
    env = { };
    # Keep the upstream helper-path patch, but omit the daemon-specific DESTDIR
    # rearrangement used by the full NixOS Polkit package.
    postInstall = "";
  }
