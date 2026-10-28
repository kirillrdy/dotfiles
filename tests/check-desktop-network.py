#!/usr/bin/env python3
"""Run native network actions against a private, event-emitting NetworkManager."""
import argparse
import json
import os
import subprocess
import tempfile
import select
import threading
import time
import sys
sys.dont_write_bytecode = True
from gi.repository import Gio, GLib

from network_server import Server, NAME, ROOT, DEVICE, AP, PROFILE, ACTIVE, V


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--dbus-config')
    opt = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='desktop-network-') as tmp:
        daemon = subprocess.Popen(['dbus-daemon', '--config-file='+opt.dbus_config if opt.dbus_config else '--session', '--nofork', '--print-address=1'], stdout=subprocess.PIPE, text=True)
        address = daemon.stdout.readline().strip()
        assert address, 'Private D-Bus daemon did not start'
        try:
            os.environ['DBUS_SYSTEM_BUS_ADDRESS'] = address
            server = Server(address)
            loop = GLib.MainLoop()
            thread = threading.Thread(target=loop.run, daemon=True)
            thread.start()
            def run(*args, fail=False):
                result = subprocess.run([opt.binary, *args], capture_output=True, text=True, timeout=15)
                assert (result.returncode != 0) == fail, (args, result.returncode, result.stdout, result.stderr)
                return json.loads(result.stdout) if result.stdout else None
            state = run('state')
            assert state['aps'][0]['title'] == 'Cafe: Tokyo\\5G'
            assert state['aps'][0]['strength'] == 83
            watcher = subprocess.Popen([opt.binary, 'events'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, bufsize=1)
            def event(predicate):
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([watcher.stdout], [], [], max(0, deadline-time.monotonic()))
                    if ready:
                        line = watcher.stdout.readline()
                        assert line, watcher.stderr.read()
                        value = json.loads(line)
                        if predicate(value): return
                raise AssertionError('Network state event timed out')
            event(lambda s: s['available'] and s['profiles'] == 1)
            initial_fetches = sum(c[0] == 'GetSettings' for c in server.calls)
            server.change(AP, NAME+'.AccessPoint', {'Strength': V('y', 42)})
            event(lambda s: s['strength'] == 42)
            server.change(ROOT, NAME, {'WirelessHardwareEnabled': V('b', False)})
            event(lambda s: not s['hardware'])
            assert sum(c[0] == 'GetSettings' for c in server.calls) == initial_fetches
            server.bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'ReleaseName', V('(s)', (NAME,)), None, 0, -1, None)
            event(lambda s: not s['available'])
            server.own()
            event(lambda s: s['available'] and s['profiles'] == 1)
            server.change(ROOT, NAME, {'WirelessHardwareEnabled': V('b', True)})
            event(lambda s: s['hardware'])
            assert watcher.wait(timeout=10) == 0, watcher.stderr.read()
            run('wifi', 'off')
            assert not run('state')['wifi']
            run('wifi', 'on')
            run('scan')
            run('connect-ap', AP, 'secret:$()\\')
            assert server.last_added['802-11-wireless']['ssid'] == list(b'Cafe: Tokyo\\5G')
            assert server.last_added['802-11-wireless-security']['psk'] == 'secret:$()\\'
            run('activate', PROFILE)
            server.change(AP, NAME+'.AccessPoint', {'Ssid': V('ay', b'Saved')})
            run('connect-ap', AP, 'changed-secret')
            assert server.settings['ipv4']['method'].unpack() == 'manual'
            assert server.settings['connection']['uuid'].unpack() == 'test-uuid'
            assert server.settings['802-11-wireless-security']['psk'].unpack() == 'changed-secret'
            server.change(AP, NAME+'.AccessPoint', {'Ssid': V('ay', b'\xff\x00bin')})
            run('connect-ap', AP, 'binary-secret')
            assert server.last_added['802-11-wireless']['ssid'] == [255, 0, 98, 105, 110]
            for flags, key, password in [(0x400, 'sae', 'sae-secret'), (0x800, 'owe', ''), (0, 'none', 'abcde')]:
                server.change(AP, NAME+'.AccessPoint', {'RsnFlags': V('u', flags)})
                run('connect-ap', AP, password)
                assert server.last_added['802-11-wireless-security']['key-mgmt'] == key
            server.activation_fail = True
            run('activate', PROFILE, fail=True)
            server.activation_fail = False
            server.deny = True
            run('scan', fail=True)
            server.deny = False
            server.delay = True
            run('cancel')
            server.delay = False
            run('disconnect', DEVICE)
            run('deactivate', PROFILE)
            run('ui')
            run('edit')
            assert server.settings['connection']['uuid'].unpack() == 'test-uuid'
            assert server.settings['connection']['id'].unpack() == 'Native connection'
            assert server.settings['proxy']['pac-url'].unpack() == 'https://proxy.example/config'
            assert server.settings['ipv4']['address-data'].unpack()[0] == {'address': '192.0.2.10', 'prefix': 24}
            assert server.settings['ipv6']['address-data'].unpack()[0] == {'address': '2001:db8::10', 'prefix': 64}
            assert server.settings['ipv4']['dns-data'].unpack() == ['1.1.1.1', '9.9.9.9']
            run('edit-secret')
            assert server.settings['802-11-wireless-security']['psk'].unpack() == 'updated-wifi-secret'
            assert server.settings['802-1x']['private-key-password'].unpack() == 'stored-key-secret'
            assert set(server.secret_reads) >= {'802-11-wireless-security', '802-1x'}
            server.stale = True
            run('edit', fail=True)
            server.stale = False
            server.deny = True
            run('edit', fail=True)
            server.deny = False
            server.delay = True
            updates_before = sum(call[0] == 'Update2' for call in server.calls)
            run('edit-cancel')
            assert sum(call[0] == 'Update2' for call in server.calls) == updates_before
            server.delay = False
            run('new')
            assert server.last_added['connection']['type'] == 'bridge'
            assert server.last_added['connection']['interface-name'] == 'fixture-br0'
            assert server.last_added['bridge']['stp']
            assert server.last_added['connection']['uuid'] != 'test-uuid'
            run('forget', PROFILE)
            loop.quit()
            thread.join(timeout=2)
            print('native network: events, daemon restarts, state, radio, scan, profiles, secrets, binary SSIDs, security, failures, cancellation and UI teardown passed')
        finally:
            daemon.terminate()
            daemon.wait(timeout=5)

if __name__ == '__main__': main()
