{ pkgs }:
pkgs.wlroots_0_20.overrideAttrs (old: {
  patches = (old.patches or [ ]) ++ [ ./wlroots-capture-bounds.patch ];
})
