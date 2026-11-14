{ pkgs }:
# EGL and GLES still dispatch to the system's GPU drivers. GLX is only used
# by X11 clients and must not retain Xlib in the Wayland desktop's closure.
pkgs.libglvnd.overrideAttrs (old: {
  pname = "desktop-libglvnd";
  buildInputs = pkgs.lib.subtractLists [ pkgs.libx11 pkgs.libxext ] old.buildInputs;
  configureFlags = old.configureFlags ++ [
    "--disable-x11"
    "--disable-glx"
  ];
  # Upstream adds the driver search path to libGLX, which is not built here.
  postFixup = "";
  doCheck = true;
  checkTarget = "check";
  outputChecks.out.disallowedRequisites = [
    pkgs.libx11
    pkgs.libxext
  ];
})
