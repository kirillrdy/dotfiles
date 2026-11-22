Desktop tests
=============

`zig build test` runs unit, ABI, protocol metadata and offscreen rendering
checks. It needs the development dependencies from `nix-shell`, but no running
compositor or D-Bus session. The desktop package runs these checks during its
build. Tests marked `integration:` are skipped in this suite.

Integration tests use `pkgs.testers.runNixOSTest` and are exposed through both
`nixosTests.x86_64-linux` and `checks.x86_64-linux` in the flake. For example:

```sh
nix build .#checks.x86_64-linux.ui
nix build .#checks.x86_64-linux.portal
nix build .#checks.x86_64-linux.desktop
```

The `ui` VM runs the inline `integration:` tests and the GUI fixtures formerly
run by the package check phase. The remaining feature VMs cover
audio, backlight, battery, idle, lock, memory, network, output, polkit, portals,
screenshots, secrets, session and shell behavior. These contract tests run as an
unprivileged user with private compositors and mock services. `desktop` tests
the production NixOS module, login session, systemd services, D-Bus activation
and real PAM authentication.

`tests/fixture.nix` compiles test clients and packages the check scripts during
the build, then executes their assertions after the VM boots. Add a feature to
`tests/default.nix` to expose it as a flake check. The standalone PAM header/ABI
check remains a build derivation because it needs no running system.

Tests that inspect private implementation state stay beside the implementation.
Prefix their names with `integration:` and guard them with
`options.integration_tests`. The UI VM builds their executable with
`zig build test-binary -Dintegration-tests=true`; its filter selects only those
tests, so the unit suite is not repeated in the VM.
