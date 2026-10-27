#!/usr/bin/env python3
"""Exercise session actions exclusively against a private logind D-Bus service."""
import argparse
import os
import subprocess
import threading
from gi.repository import Gio, GLib

NAME = 'org.freedesktop.login1'
ROOT = '/org/freedesktop/login1'
SESSION = ROOT + '/session/test'
MANAGER = NAME + '.Manager'
V = GLib.Variant


class Logind:
    def __init__(self, address):
        self.bus = Gio.DBusConnection.new_for_address_sync(
            address, Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT |
            Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.calls = []
        self.pending = []
        self.capability = 'yes'
        self.deny = None
        self.delay = None
        manager = '<node><interface name="' + MANAGER + '">'
        for action in ['Suspend', 'Reboot', 'PowerOff']:
            manager += f'<method name="Can{action}"><arg type="s" direction="out"/></method>'
            manager += f'<method name="{action}"><arg type="b" direction="in"/></method>'
        manager += '<method name="TerminateSession"><arg type="s" direction="in"/></method>'
        manager += '<method name="GetSessionByPID"><arg type="u" direction="in"/><arg type="o" direction="out"/></method>'
        manager += '</interface></node>'
        self.bus.register_object(ROOT, Gio.DBusNodeInfo.new_for_xml(manager).interfaces[0], self.method, None, None)
        session = f'<node><interface name="{NAME}.Session"><method name="Terminate"/></interface></node>'
        self.bus.register_object(SESSION, Gio.DBusNodeInfo.new_for_xml(session).interfaces[0], self.method, None, None)
        self.own(True)

    def own(self, acquire):
        self.bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus',
                           'RequestName' if acquire else 'ReleaseName',
                           V('(su)', (NAME, 0)) if acquire else V('(s)', (NAME,)),
                           None, 0, -1, None)

    def method(self, bus, sender, path, interface, method, parameters, invocation):
        args = parameters.unpack()
        self.calls.append((path, method, args))
        if method == self.deny:
            invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied', 'Session action denied')
        elif method == self.delay:
            self.pending.append(invocation)
        elif method.startswith('Can'):
            invocation.return_value(V('(s)', (self.capability,)))
        elif method == 'GetSessionByPID':
            assert args[0] > 0
            invocation.return_value(V('(o)', (SESSION,)))
        else:
            if method in ['Suspend', 'Reboot', 'PowerOff']:
                assert args == (True,), (method, args)
            invocation.return_value(V('()', ()))

    def reset(self):
        for invocation in self.pending:
            invocation.return_dbus_error('org.freedesktop.DBus.Error.Failed', 'Fixture reset')
        self.pending.clear()
        self.calls.clear()
        self.capability = 'yes'
        self.deny = self.delay = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True)
    options = parser.parse_args()
    address = os.environ['DBUS_SESSION_BUS_ADDRESS']
    server = Logind(address)
    loop = GLib.MainLoop()
    thread = threading.Thread(target=loop.run, daemon=True)
    thread.start()
    count = 0

    def run(action='suspend', scenario='normal', expected='success', session_id='fixture-session'):
        nonlocal count
        env = dict(os.environ, DESKTOP_SESSION_TEST_RUN='1', DBUS_SYSTEM_BUS_ADDRESS=address,
                   SESSION_CASE=scenario, SESSION_ACTION=action, SESSION_EXPECT=expected)
        env.pop('XDG_SESSION_ID', None)
        if session_id is not None:
            env['XDG_SESSION_ID'] = session_id
        result = subprocess.run([options.binary], env=env, capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, (action, scenario, expected, result.stdout, result.stderr)
        count += 1
        return [(method, args) for path, method, args in server.calls]

    try:
        for action, method in [('suspend', 'Suspend'), ('reboot', 'Reboot'), ('poweroff', 'PowerOff')]:
            server.reset()
            assert run(action) == [('Can' + method, ()), (method, (True,))]
        for capability in ['yes', 'challenge']:
            server.reset()
            server.capability = capability
            assert run()[-1] == ('Suspend', (True,))
        for capability, message in [('na', 'not supported'), ('no', 'not permitted'),
                                    ('inhibited', 'inhibited'), ('inhibitor-blocked', 'inhibited'),
                                    ('challenge-inhibitor-blocked', 'inhibited'), ('unknown', 'unavailable')]:
            server.reset()
            server.capability = capability
            assert run(expected=message) == [('CanSuspend', ())]
        for method in ['CanSuspend', 'Suspend']:
            server.reset()
            server.deny = method
            assert run(expected='denied')[-1][0] == method
        for session_id in ['fixture:session\\1', '', None]:
            server.reset()
            calls = run('logout', session_id=session_id)
            if session_id:
                assert calls == [('TerminateSession', (session_id,))]
            else:
                assert calls[0][0] == 'GetSessionByPID' and calls[-1] == ('Terminate', ())
                assert server.calls[-1][0] == SESSION
        for method, session_id in [('TerminateSession', 'fixture'), ('GetSessionByPID', None), ('Terminate', None)]:
            server.reset()
            server.deny = method
            assert run('logout', expected='denied', session_id=session_id)[-1][0] == method
        server.reset()
        assert run(scenario='cancel-immediate', expected='cancelled') == []
        for method in ['CanSuspend', 'Suspend', 'GetSessionByPID']:
            server.reset()
            server.delay = method
            calls = run('logout' if method == 'GetSessionByPID' else 'suspend',
                        scenario='cancel-delayed-' + method, expected='cancelled', session_id=None)
            assert calls[-1][0] == method
        server.reset()
        server.delay = 'CanSuspend'
        assert run(expected='Timeout') == [('CanSuspend', ())]
        server.reset()
        server.own(False)
        run(expected='org.freedesktop.login1')
        server.own(True)
        server.reset()
        run()  # A restarted daemon must work on the next request.
        server.reset()
        server.deny = 'Suspend'
        assert run(scenario='ui-denied') == [('CanSuspend', ()), ('Suspend', (True,))]
        server.reset()
        server.delay = 'Suspend'
        assert run(scenario='ui-teardown') == [('CanSuspend', ()), ('Suspend', (True,))]
        print(f'native session: {count} cases passed (actions, capabilities, authorization, logout, cancellation, timeout, daemon restart, UI errors and teardown)')
    finally:
        server.reset()
        loop.quit()
        thread.join(timeout=2)


if __name__ == '__main__':
    main()
