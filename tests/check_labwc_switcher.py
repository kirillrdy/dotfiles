"""Exercise the native switcher in a private headless Labwc session.

Build the fixture with tests/labwc-switcher-fixture.nix, then pass its binary,
NixOS system output, and wtype. Requires dbus-run-session and private sockets.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time


def wait_for(predicate, message, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(message)


def inside(args):
    root = Path(os.environ['XDG_RUNTIME_DIR']).parent
    processes = []
    logs = []
    env = dict(os.environ)
    env['WAYLAND_DISPLAY'] = 'wayland-0'

    def run(*command):
        return subprocess.run(command, env=env, check=True, capture_output=True,
                              text=True, timeout=10)

    def start(command, log):
        handle = (root / log).open('w')
        logs.append(handle)
        process = subprocess.Popen(command, env=env, stdout=handle, stderr=handle)
        processes.append(process)
        return process

    def focused():
        events = []
        for path in root.glob('window-*.log'):
            for line in path.read_text().splitlines():
                stamp, _, title = line.partition(' ')
                if stamp.isdecimal():
                    events.append((int(stamp), title))
        return max(events, default=(0, ''))[1]

    def keys(*arguments):
        run(args.wtype, *arguments)
        time.sleep(0.2)

    def expect(title):
        wait_for(lambda: focused() == title,
                 f'Expected focus on {title}; got {focused()}')

    try:
        compositor = start(['labwc', '-C', os.environ['XDG_CONFIG_HOME'] + '/labwc', '-V'],
                           'labwc.log')
        wait_for(lambda: (Path(os.environ['XDG_RUNTIME_DIR']) / 'wayland-0').exists(),
                 'Compositor did not create its Wayland socket')
        run('wlr-randr', '--output', 'HEADLESS-1', '--custom-mode',
            '2880x1800', '--scale', '1.6666666667')
        # Headless outputs have no physical keyboard. Keep one attached so
        # clients receive activation events between individual key sequences.
        start([args.wtype, '-s', '55000'], 'keyboard-seat.log')
        time.sleep(0.2)
        windows = {}
        for title, app in [('Browser 1', 'Browser'), ('Browser 2', 'Browser'),
                           ('Terminal', 'Terminal'), ('Files', 'Files')]:
            windows[title] = start([args.fixture, f'io.test.{app}', title],
                                   f'window-{title.replace(" ", "-")}.log')
            expect(title)

        # Browser's two windows occupy one application slot. The background
        # remains focused until Alt is released, as in GNOME.
        held = start([args.wtype, '-M', 'alt', '-k', 'Tab', '-k', 'Tab',
                      '-s', '1800', '-m', 'alt'], 'keyboard.log')
        time.sleep(0.8)
        assert focused() == 'Files', 'Cycling changed focus before Alt release'
        run('grim', '-g', '350,280 1028x720', str(root / 'switcher.png'))
        held.wait(timeout=5)
        expect('Browser 2')
        print('PASS application grouping and Alt release', flush=True)

        keys('-M', 'alt', '-M', 'shift', '-k', 'Tab', '-m', 'shift', '-m', 'alt')
        expect('Terminal')
        print('PASS reverse cycling', flush=True)

        keys('-M', 'alt', '-k', 'Tab', '-k', 'Escape', '-m', 'alt')
        expect('Terminal')
        print('PASS Escape cancellation', flush=True)

        keys('-M', 'alt', '-k', 'Tab', '-k', 'Down', '-k', 'Right', '-m', 'alt')
        expect('Browser 1')
        print('PASS application window navigation', flush=True)

        keys('-M', 'alt', '-k', 'grave', '-m', 'alt')
        expect('Browser 2')
        print('PASS Alt-grave within an application', flush=True)

        held = start([args.wtype, '-M', 'alt', '-k', 'Tab', '-k', 'Tab',
                      '-s', '1800', '-m', 'alt'], 'keyboard-close.log')
        time.sleep(0.6)
        windows['Files'].terminate()
        windows['Files'].wait(timeout=5)
        held.wait(timeout=5)
        assert compositor.poll() is None, 'Compositor exited while a window closed'
        print('PASS closing a window during switching', flush=True)

        for title in ('Terminal', 'Browser 2'):
            windows[title].terminate()
            windows[title].wait(timeout=5)
        expect('Browser 1')
        keys('-M', 'alt', '-k', 'Tab', '-m', 'alt')
        expect('Browser 1')
        print('PASS single window', flush=True)
        windows['Browser 1'].terminate()
        windows['Browser 1'].wait(timeout=5)
        keys('-M', 'alt', '-k', 'Tab', '-m', 'alt')
        assert compositor.poll() is None, 'Compositor exited with no windows'
        print('PASS no windows', flush=True)
        compositor_log = (root / 'labwc.log').read_text()
        assert 'Invalid windowSwitcher' not in compositor_log
        assert '[ERROR]' not in compositor_log, compositor_log
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for handle in logs:
            handle.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--system', required=True, type=Path)
    parser.add_argument('--fixture', required=True)
    parser.add_argument('--wtype', default='wtype')
    parser.add_argument('--dbus-run-session', default='dbus-run-session')
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    args.system = args.system.resolve()
    if args.inside:
        inside(args)
        return
    root = Path(tempfile.mkdtemp(prefix='labwc-switcher-'))
    (root / 'runtime').mkdir(mode=0o700)
    config = root / 'config' / 'labwc'
    config.mkdir(parents=True)
    shutil.copy(args.system / 'etc/xdg/labwc/rc.xml', config / 'rc.xml')
    (config / 'autostart').write_text('')
    (config / 'environment').write_text('LABWC_UPDATE_ACTIVATION_ENV=false\n')
    applications = root / 'data' / 'applications'
    applications.mkdir(parents=True)
    for app, icon in [('Browser', 'firefox'), ('Terminal', 'com.mitchellh.ghostty'),
                      ('Files', 'org.xfce.thunar')]:
        (applications / f'io.test.{app}.desktop').write_text(
            f'[Desktop Entry]\nType=Application\nName={app}\nIcon={icon}\nExec=true\n')
    bus = root / 'dbus.conf'
    bus.write_text('<busconfig><type>session</type><listen>unix:tmpdir='
                   + str(root / 'runtime') + '</listen><policy context="default">'
                   '<allow send_destination="*"/><allow receive_sender="*"/>'
                   '<allow own="*"/></policy></busconfig>')
    env = dict(os.environ)
    for name in ('DISPLAY', 'WAYLAND_DISPLAY', 'DBUS_SESSION_BUS_ADDRESS', 'LABWC_PID'):
        env.pop(name, None)
    env.update(XDG_RUNTIME_DIR=str(root / 'runtime'),
               XDG_CONFIG_HOME=str(root / 'config'), XDG_DATA_HOME=str(root / 'data'),
               XDG_DATA_DIRS=str(args.system / 'sw/share'),
               XDG_CACHE_HOME=str(root / 'cache'),
               WLR_BACKENDS='headless', WLR_RENDERER='pixman', WLR_HEADLESS_OUTPUTS='1',
               LABWC_UPDATE_ACTIVATION_ENV='false', XDG_CURRENT_DESKTOP='labwc',
               NO_AT_BRIDGE='1', GTK_USE_PORTAL='0', GIO_USE_VFS='local',
               PATH=str(args.system / 'sw/bin') + ':' + env['PATH'])
    print(f'Test artifacts: {root}', flush=True)
    print(f'System: {args.system}', flush=True)
    result = subprocess.run([args.dbus_run_session, '--config-file=' + str(bus), '--',
                             sys.executable, str(Path(__file__).resolve()),
                             '--system', str(args.system), '--fixture', args.fixture,
                             '--wtype', args.wtype, '--inside'], env=env, timeout=60)
    raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
