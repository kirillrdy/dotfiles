{ pkgs }:
pkgs.testers.runNixOSTest {
  name = "desktop";
  node.specialArgs.enableLightDesktop = true;
  node.pkgsReadOnly = false;

  nodes.machine =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    {
      imports = [ ../labwc.nix ];
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
      # Start the production session script through greetd, avoiding manual
      # compositor, D-Bus and systemd environment setup in the test driver.
      services.greetd.settings.initial_session = {
        user = "alice";
        command = lib.last (
          lib.splitString " --cmd " config.services.greetd.settings.default_session.command
        );
      };
      environment.sessionVariables.WLR_RENDERER = "pixman";
      environment.sessionVariables.GI_TYPELIB_PATH =
        lib.makeSearchPathOutput "lib" "lib/girepository-1.0"
          [
            pkgs.gtk3
            pkgs.pango
            pkgs.atk
            pkgs.gdk-pixbuf
            pkgs.gobject-introspection
            pkgs.harfbuzz
          ];
      environment.sessionVariables.GDK_PIXBUF_MODULE_FILE = "${pkgs.librsvg}/lib/gdk-pixbuf-2.0/2.10.0/loaders.cache";
      environment.systemPackages = with pkgs; [
        wtype
        wlrctl
        grim
        (python3.withPackages (p: [ p.pygobject3 ]))
        gtk3
        librsvg
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
          "greetd.service"
        ];
        requiredBy = [
          "desktop-battery.service"
          "greetd.service"
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
    machine.wait_for_unit("greetd.service")
    machine.wait_for_unit("desktop-battery.service")
    machine.wait_for_file("/run/user/1000/wayland-0")
    machine.wait_until_succeeds(user("desktop-zig ping"))

    with subtest("production services and D-Bus activation"):
        for service in ("desktop-session.target", "desktop-secrets.service"):
            machine.wait_until_succeeds(user("systemctl --user is-active " + service))
        machine.succeed(user("busctl --user introspect org.freedesktop.Notifications /org/freedesktop/Notifications"))
        machine.succeed(user("busctl --user introspect org.freedesktop.portal.Desktop /org/freedesktop/portal/desktop"))
        machine.succeed(user("busctl --user introspect org.freedesktop.secrets /org/freedesktop/secrets"))

    with subtest("full battery below 100 percent resolves to a real rendered icon"):
        assert power_property("State") == "u 4"
        assert power_property("IconName") == 's "battery-level-100-charged-symbolic"'
        check_icon = (
            "import gi; gi.require_version('Gtk', '3.0'); "
            "from gi.repository import Gtk; Gtk.init([]); "
            "theme = Gtk.IconTheme.get_default(); "
            "icon = theme.load_icon('battery-level-100-charged-symbolic', 16, 0); "
            "assert icon.get_width() > 0 and icon.get_height() > 0"
        )
        machine.succeed(user("python3 -c " + shlex.quote(check_icon)))
        machine.screenshot("desktop-charged-battery")
        machine.succeed("echo Discharging > /run/test-power/BAT0/status; echo 0 > /run/test-power/AC/online; echo 72000000 > /run/test-power/BAT0/energy_now")
        machine.wait_until_succeeds(
            "busctl --system get-property org.freedesktop.UPower "
            "/org/freedesktop/UPower/devices/DisplayDevice "
            "org.freedesktop.UPower.Device IconName | grep battery-level-70-symbolic"
        )

    with subtest("settings opens through the production session"):
        machine.succeed(user("desktop-zig settings sound"))
        machine.wait_until_succeeds(user("wlrctl toplevel find title:Sound"))
        machine.screenshot("desktop-sound-settings")
        machine.succeed(user("wlrctl toplevel close title:Sound"))

    with subtest("production lock authenticates using the VM's real PAM policy"):
        machine.succeed(user("systemd-run --user --unit=test-lock --setenv=WAYLAND_DEBUG=client desktop-zig lock"))
        machine.wait_until_succeeds("journalctl --no-pager _SYSTEMD_USER_UNIT=test-lock.service | grep -F '.locked()'")
        machine.succeed(user("wtype -d 10 incorrect -k Return"))
        machine.wait_until_succeeds("journalctl --no-pager | grep 'pam_unix(desktop-lock:auth): authentication failure'")
        machine.succeed(user("systemctl --user is-active test-lock.service"))
        # PAM's randomized failure delay precedes the lock client's own retry delay.
        machine.sleep(5)
        machine.succeed(user("wtype -d 10 vm-password -k Return"))
        machine.wait_until_succeeds("journalctl --no-pager _SYSTEMD_USER_UNIT=test-lock.service | grep unlock_and_destroy")
        machine.wait_until_fails(user("systemctl --user is-active test-lock.service"))
        machine.succeed(user("desktop-zig ping"))
  '';
}
