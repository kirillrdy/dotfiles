{ pkgs }:
let
  # The same boot, login and session on the wlroots-free compositor.
  native = pkgs.desktopNativeCompositor or false;
in
pkgs.testers.runNixOSTest {
  name = if native then "desktop-native" else "desktop";
  node.specialArgs.enableLightDesktop = true;
  node.specialArgs.enableNvidia = false;
  node.specialArgs.enableNativeCompositor = native;
  node.pkgsReadOnly = false;

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ ../desktop.nix ];
      virtualisation = {
        memorySize = 2048;
        cores = 2;
        resolution = {
          x = 1280;
          y = 800;
        };
        qemu.options = [ "-vga none -device virtio-gpu-pci" ];
      };
      users.users.alice = {
        isNormalUser = true;
        uid = 1000;
        password = "vm-password";
        extraGroups = [
          "wheel"
          "networkmanager"
          "video"
        ];
      };
      systemd.services.desktop-display-manager.environment.WLR_RENDERER = "pixman";
      environment.sessionVariables.WLR_RENDERER = "pixman";
      environment.systemPackages = with pkgs; [
        wtype
        wlrctl
        grim
        wayland-utils
        mesa-demos
      ];
      fonts.packages = [ pkgs.dejavu_fonts ];
      services.pipewire = {
        enable = true;
        pulse.enable = true;
        wireplumber.enable = true;
      };

      # Mount controlled readings at the real kernel path inside the VM.
      # The production reader and its systemd sandbox remain unchanged.
      systemd.services.test-power-supply = {
        path = [ pkgs.util-linux ];
        before = [
          "desktop-battery.service"
          "desktop-display-manager.service"
        ];
        requiredBy = [
          "desktop-battery.service"
          "desktop-display-manager.service"
        ];
        serviceConfig.Type = "oneshot";
        serviceConfig.RemainAfterExit = true;
        script = ''
          mkdir -p /run/test-power/BAT0 /run/test-power/AC
          echo Battery > /run/test-power/BAT0/type
          echo System > /run/test-power/BAT0/scope
          echo 1 > /run/test-power/BAT0/present
          echo Full > /run/test-power/BAT0/status
          echo 99880000 > /run/test-power/BAT0/energy_now
          echo 100000000 > /run/test-power/BAT0/energy_full
          echo 0 > /run/test-power/BAT0/power_now
          echo Mains > /run/test-power/AC/type
          echo 1 > /run/test-power/AC/online
          mount --bind /run/test-power /sys/class/power_supply
        '';
      };
    };

  testScript = ''
    from datetime import timedelta
    import shlex

    def user(command):
        return "su - alice -c " + shlex.quote(
            "env XDG_RUNTIME_DIR=/run/user/1000 "
            "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
            "WAYLAND_DISPLAY=wayland-0 GDK_BACKEND=wayland " + command
        )

    def power_property(name):
        return machine.succeed(
            "busctl --system get-property org.freedesktop.UPower "
            "/org/freedesktop/UPower/devices/DisplayDevice "
            "org.freedesktop.UPower.Device " + name
        ).strip()

    machine.start()
    machine.wait_for_unit("desktop-display-manager.service")
    machine.wait_for_unit("desktop-battery.service")
    machine.wait_until_succeeds(
        "journalctl --no-pager | grep -F 'greeter: keyboard focus ready'",
        timeout=timedelta(seconds=60),
    )

    with subtest("GDM-like greeter authenticates and starts desktop-zig.service"):
        machine.screenshot("desktop-greeter-users")
        # Select pre-highlighted Alice user and open password prompt.
        machine.send_key("ret")
        machine.sleep(1)
        machine.screenshot("desktop-greeter-password")
        machine.send_chars("wrong-password\n")
        machine.wait_until_succeeds(
            "journalctl --no-pager | grep 'pam_unix(desktop-login:auth): authentication failure'",
            timeout=timedelta(seconds=60),
        )
        machine.sleep(4)
        machine.send_chars("vm-password\n")
        machine.wait_for_file("/run/user/1000/wayland-0")
        machine.wait_until_succeeds(user("desktop-zig ping"))
        machine.wait_until_succeeds(user("systemctl --user is-active desktop-zig.service"))
        machine.wait_until_succeeds("journalctl --no-pager _SYSTEMD_USER_UNIT=desktop-zig.service | grep -q .")

    with subtest("production services and D-Bus activation"):
        for service in ("desktop-zig.service", "desktop-session.target", "desktop-secrets.service"):
            machine.wait_until_succeeds(user("systemctl --user is-active " + service))
        machine.succeed(user("busctl --user introspect org.freedesktop.Notifications /org/freedesktop/Notifications"))
        machine.succeed(user("busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop"))
        machine.succeed(user("busctl --user introspect org.freedesktop.secrets /org/freedesktop/secrets"))

    with subtest("full battery below 100 percent resolves to a real rendered icon"):
        assert power_property("State") == "u 4"
        assert power_property("IconName") == 's "battery-level-100-charged-symbolic"'
        machine.succeed("test -s ${pkgs.adwaita-icon-theme}/share/icons/Adwaita/symbolic/status/battery-level-100-charged-symbolic.svg")
        machine.screenshot("desktop-charged-battery")
        machine.succeed("echo Discharging > /run/test-power/BAT0/status; echo 0 > /run/test-power/AC/online; echo 72000000 > /run/test-power/BAT0/energy_now")
        machine.wait_until_succeeds(
            "busctl --system get-property org.freedesktop.UPower "
            "/org/freedesktop/UPower/devices/DisplayDevice "
            "org.freedesktop.UPower.Device IconName | grep battery-level-70-symbolic"
        )

    with subtest("settings opens through the production session"):
        machine.succeed(user("desktop-zig settings"))
        machine.wait_until_succeeds(user("wlrctl toplevel find title:Settings"))
        machine.succeed(user("desktop-zig settings sound"))
        machine.wait_until_succeeds(user("wlrctl toplevel find title:Settings"))
        machine.screenshot("desktop-sound-settings")
        machine.succeed(user("wlrctl toplevel close title:Settings"))

    # wlroots leaves Ctrl+Alt+Fn to compositors, and the wlroots one never handled it.
    if ${if native then "True" else "False"}:
      with subtest("the native compositor composites on the GPU"):
        machine.succeed("journalctl -b | grep -F 'compositor: rendering with GLES'")
      with subtest("GL clients get the linux-dmabuf format table"):
        print(machine.succeed(user("wayland-info -i zwp_linux_dmabuf_v1 | head -40")))
        machine.succeed(user("wayland-info -i zwp_linux_dmabuf_v1 | grep -i 'main device'"))
        machine.succeed(user("systemd-run --user --unit=gears es2gears_wayland"))
        machine.sleep(4)
        machine.succeed(user("systemctl --user is-active gears.service"))
        machine.screenshot("desktop-gl-client")
        machine.fail("journalctl -b | grep -F 'could not import'")
        machine.succeed(user("systemctl --user stop gears.service"))
      with subtest("overview previews draw on the GPU and the panel turns opaque again"):
        machine.succeed(user("desktop-zig settings"))
        machine.wait_until_succeeds(user("wlrctl toplevel find title:Settings"))
        machine.succeed(user("desktop-zig overview"))
        machine.sleep(2)
        machine.screenshot("desktop-overview-open")
        machine.send_key("esc")
        machine.sleep(2)
        machine.screenshot("desktop-overview-closed")
        machine.succeed(user("wlrctl toplevel close title:Settings"))
      with subtest("the session survives switching to another VT and back"):
        machine.send_key("ctrl-alt-f2")
        machine.wait_until_succeeds("test \"$(cat /sys/class/tty/tty0/active)\" = tty2")
        machine.send_key("ctrl-alt-f1")
        machine.wait_until_succeeds("test \"$(cat /sys/class/tty/tty0/active)\" = tty1")
        machine.succeed(user("desktop-zig ping"))
        machine.sleep(1)
        machine.screenshot("desktop-after-vt-switch")
        machine.succeed(user("systemctl --user is-active desktop-zig.service"))

    with subtest("a configuration switch re-activating getty.target leaves the session running"):
        machine.succeed("systemctl start getty.target")
        machine.sleep(2)
        machine.succeed("systemctl is-active desktop-display-manager.service")
        machine.succeed(user("systemctl --user is-active desktop-zig.service"))

    with subtest("production lock authenticates using the VM's real PAM policy"):
        machine.succeed(user("systemd-run --user --unit=test-lock --setenv=WAYLAND_DEBUG=client desktop-zig lock"))
        machine.wait_until_succeeds("journalctl --no-pager _SYSTEMD_USER_UNIT=test-lock.service | grep -F '.locked()'")
        machine.succeed(user("wtype -d 10 incorrect -k Return"))
        machine.wait_until_succeeds("journalctl --no-pager | grep 'pam_unix(desktop-lock:auth): authentication failure'")
        machine.succeed(user("systemctl --user is-active test-lock.service"))
        # PAM's randomized failure delay precedes the lock client's own retry delay.
        machine.sleep(5)
        # The physical keyboard still reaches clients after the VT round trip.
        machine.send_chars("vm-password\n")
        machine.wait_until_succeeds("journalctl --no-pager _SYSTEMD_USER_UNIT=test-lock.service | grep unlock_and_destroy")
        machine.wait_until_fails(user("systemctl --user is-active test-lock.service"))
        machine.succeed(user("desktop-zig ping"))

    with subtest("stopping the display manager ends the session instead of orphaning it"):
        # Well under systemd's 90 s stop timeout, which used to expire.
        machine.succeed("timeout 30 systemctl stop desktop-display-manager.service")
        machine.wait_until_fails(user("systemctl --user is-active desktop-zig.service"), timeout=30)
        machine.wait_until_fails("loginctl list-sessions --no-legend | grep -w tty1", timeout=30)
  '';
}
