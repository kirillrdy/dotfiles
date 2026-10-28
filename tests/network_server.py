"""Private NetworkManager D-Bus mock shared by integration and leak checks."""
from gi.repository import Gio, GLib

NAME = 'org.freedesktop.NetworkManager'
ROOT = '/org/freedesktop/NetworkManager'
DEVICE = ROOT + '/Devices/1'
AP = ROOT + '/AccessPoint/1'
PROFILE = ROOT + '/Settings/1'
ACTIVE = ROOT + '/ActiveConnection/1'
OM = 'org.freedesktop.DBus.ObjectManager'
PROPS = 'org.freedesktop.DBus.Properties'
V = GLib.Variant

class Server:
    def __init__(self, address):
        self.bus = Gio.DBusConnection.new_for_address_sync(address,
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION, None, None)
        self.objects = {}
        self.registrations = []
        self.calls = []
        self.deny = False
        self.activation_fail = False
        self.delay = False
        self.stale = False
        self.secret_reads = []
        self.secrets = {'802-11-wireless-security': {'psk': V('s', 'stored-wifi-secret')}, '802-1x': {'private-key-password': V('s', 'stored-key-secret')}}
        self.settings = {
            'connection': {'id': V('s', 'Saved'), 'uuid': V('s', 'test-uuid'), 'type': V('s', '802-11-wireless')},
            '802-11-wireless': {'ssid': V('ay', b'Saved')},
            '802-11-wireless-security': {'key-mgmt': V('s', 'wpa-psk')},
            '802-1x': {'eap': V('as', ['tls'])},
            'proxy': {'method': V('i', 0), 'pac-url': V('s', 'https://proxy.example/config')},
            'ipv4': {'method': V('s', 'manual'), 'dns': V('au', [0x01010101])},
        }
        self.add('/org/freedesktop', OM, {}, {'GetManagedObjects': ('', 'a{oa{sa{sv}}}')})
        self.add(ROOT, NAME, {'WirelessEnabled': V('b', True), 'WirelessHardwareEnabled': V('b', True), 'PrimaryConnection': V('o', '/')}, {
            'ActivateConnection': ('ooo', 'o'), 'AddAndActivateConnection': ('a{sa{sv}}oo', 'oo'), 'DeactivateConnection': ('o', '')})
        self.add(DEVICE, NAME+'.Device', {'DeviceType': V('u', 2), 'Interface': V('s', 'wlan0'), 'State': V('u', 30), 'Managed': V('b', True), 'ActiveConnection': V('o', '/')}, {'Disconnect': ('', '')})
        self.add(DEVICE, NAME+'.Device.Wireless', {'AccessPoints': V('ao', [AP]), 'ActiveAccessPoint': V('o', '/')}, {'RequestScan': ('a{sv}', '')})
        self.add(AP, NAME+'.AccessPoint', {'Ssid': V('ay', b'Cafe: Tokyo\\5G'), 'Strength': V('y', 83), 'Flags': V('u', 1), 'WpaFlags': V('u', 0), 'RsnFlags': V('u', 0x100)}, {})
        self.add(ROOT+'/Settings', NAME+'.Settings', {}, {'AddConnection': ('a{sa{sv}}', 'o')})
        self.add(PROFILE, NAME+'.Settings.Connection', {'VersionId': V('t', 1)}, {'GetSettings': ('', 'a{sa{sv}}'), 'GetSecrets': ('s', 'a{sa{sv}}'), 'Update2': ('a{sa{sv}}ua{sv}', 'a{sv}'), 'Update': ('a{sa{sv}}', ''), 'Delete': ('', '')}, '<signal name="Updated"/>')
        self.own()

    def own(self):
        self.bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', V('(su)', (NAME, 0)), None, 0, -1, None)

    def add(self, path, iface, properties, methods, signals=''):
        # Split signatures using GLib, including nested dictionary types.
        def args(signature, direction):
            result = ''
            remaining = signature
            while remaining:
                # PyGI's scanner is inconvenient; consume one complete type recursively.
                def consume(s, i=0):
                    if s[i] == 'a': return consume(s, i+1)
                    if s[i] in '({':
                        end = ')' if s[i] == '(' else '}'
                        i += 1
                        while s[i] != end: i = consume(s, i)
                        return i+1
                    return i+1
                n = consume(remaining)
                result += f'<arg type="{remaining[:n]}" direction="{direction}"/>'
                remaining = remaining[n:]
            return result
        xml = '<node><interface name="'+iface+'">'
        for key, val in properties.items(): xml += f'<property name="{key}" type="{val.get_type_string()}" access="readwrite"/>'
        for key, (ins, outs) in methods.items(): xml += '<method name="'+key+'">'+args(ins, 'in')+args(outs, 'out')+'</method>'
        xml += signals+'</interface></node>'
        info = Gio.DBusNodeInfo.new_for_xml(xml).interfaces[0]
        reg = self.bus.register_object(path, info, self.method, self.get, self.set)
        self.registrations.append(reg)
        self.objects.setdefault(path, {})[iface] = properties
        if path != '/org/freedesktop':
            self.bus.emit_signal(None, '/org/freedesktop', OM, 'InterfacesAdded', V('(oa{sa{sv}})', (path, {iface: properties})))

    def get(self, bus, sender, path, iface, key): return self.objects[path][iface][key]

    def set(self, bus, sender, path, iface, key, value):
        self.calls.append(('Set', key, value.unpack()))
        if self.deny: return False
        self.change(path, iface, {key: value})
        return True

    def change(self, path, iface, values):
        self.objects[path][iface].update(values)
        self.bus.emit_signal(None, path, PROPS, 'PropertiesChanged', V('(sa{sv}as)', (iface, values, [])))

    def method(self, bus, sender, path, iface, method, params, invocation):
        self.calls.append((method, params.unpack()))
        if self.deny and method not in ('GetManagedObjects', 'GetSettings'):
            invocation.return_dbus_error(NAME+'.PermissionDenied', 'fixture permission denied')
            return
        if self.delay and method in ('RequestScan', 'GetSecrets', 'Update2'):
            reply = V('(a{sa{sv}})', ({},)) if method == 'GetSecrets' else V('(a{sv})', ({},)) if method == 'Update2' else V('()', ())
            GLib.timeout_add(500, lambda: (invocation.return_value(reply), False)[1])
            return
        if method == 'GetManagedObjects':
            invocation.return_value(V('(a{oa{sa{sv}}})', ({p:i for p,i in self.objects.items() if p != '/org/freedesktop'},)))
        elif method == 'GetSettings': invocation.return_value(V('(a{sa{sv}})', (self.settings,)))
        elif method == 'GetSecrets':
            group = params.unpack()[0]
            self.secret_reads.append(group)
            invocation.return_value(V('(a{sa{sv}})', ({group: self.secrets.get(group, {})},)))
        elif method == 'AddConnection':
            self.last_added = params.unpack()[0]
            invocation.return_value(V('(o)', (ROOT+'/Settings/2',)))
        elif method == 'Update2' and (self.stale or params.unpack()[2].get('version-id') != self.objects[PROFILE][NAME+'.Settings.Connection']['VersionId'].unpack()):
            invocation.return_dbus_error(NAME+'.Settings.VersionIdMismatch', 'Profile changed since the editor opened')
        elif method in ('Update', 'Update2'):
            self.settings = {group: {key: params.get_child_value(0).lookup_value(group, None).lookup_value(key, None) for key in values} for group, values in params.unpack()[0].items()}
            self.change(PROFILE, NAME+'.Settings.Connection', {'VersionId': V('t', self.objects[PROFILE][NAME+'.Settings.Connection']['VersionId'].unpack()+1)})
            self.bus.emit_signal(None, path, iface, 'Updated', None)
            invocation.return_value(V('(a{sv})', ({},)) if method == 'Update2' else V('()', ()))
        elif method in ('ActivateConnection', 'AddAndActivateConnection'):
            if method == 'AddAndActivateConnection':
                self.last_added = params.unpack()[0]
                profile = PROFILE
            else: profile = params.unpack()[0]
            if ACTIVE not in self.objects:
                self.add(ACTIVE, NAME+'.Connection.Active', {'Connection': V('o', profile), 'Id': V('s', 'Connected'), 'Type': V('s', '802-11-wireless'), 'State': V('u', 1)}, {})
            else: self.change(ACTIVE, NAME+'.Connection.Active', {'State': V('u', 1)})
            invocation.return_value(V('(o)', (ACTIVE,)) if method == 'ActivateConnection' else V('(oo)', (profile, ACTIVE)))
            def activated():
                self.change(ACTIVE, NAME+'.Connection.Active', {'State': V('u', 4 if self.activation_fail else 2)})
                return False
            GLib.timeout_add(50, activated)
        elif method == 'Delete':
            interfaces = self.objects.pop(path)
            self.bus.emit_signal(None, '/org/freedesktop', OM, 'InterfacesRemoved', V('(oas)', (path, list(interfaces))))
            invocation.return_value(V('()', ()))
        else: invocation.return_value(V('()', ()))
