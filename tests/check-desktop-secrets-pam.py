"""Validate the PAM token bridge using private policies and dummy credentials."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--fixture", required=True)
parser.add_argument("--bridge", required=True)
parser.add_argument("--token", required=True)
parser.add_argument("--permit", required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix="desktop-secrets-pam-", dir="/tmp") as tmp:
    root = Path(tmp)
    marker = root / "received"
    helper = root / "receiver"
    helper.write_text(f"#!{sys.executable}\n" +
        "import os,sys\nfrom pathlib import Path\n" +
        "assert sys.argv[1:] == ['secrets-login']\n" +
        "assert sys.stdin.buffer.read() == b'integration-vault-password'\n" +
        f"assert os.geteuid() == {os.getuid()}\n" +
        f"assert os.environ['DBUS_SESSION_BUS_ADDRESS'] == 'unix:path=/run/user/{os.getuid()}/bus'\n" +
        "assert 'integration-vault-password' not in str(dict(os.environ))\n" +
        f"Path({str(marker)!r}).write_text('ok')\n")
    helper.chmod(0o700)
    (root / "login-test").write_text(f"auth sufficient {args.token}\n")
    (root / "greetd-test").write_text(
        "auth substack login-test\n" +
        f"auth optional {args.bridge}\n" +
        f"session required {args.token}\n" +
        f"session optional {args.bridge} helper={helper}\n" +
        f"session required {args.permit}\n")
    subprocess.run([args.fixture, str(root)], check=True, timeout=40)
    assert marker.read_text() == "ok"
print("PAM bridge: login substack token capture, pipe delivery, user identity, and credential cleanup passed")
