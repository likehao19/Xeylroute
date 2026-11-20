"""Exercise the desktop TUN worker on an elevated, disposable Windows test machine."""
import ctypes
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import struct
import subprocess
import sys
import tempfile
import time


def test_route_exists(device, prefix):
    query = (f"$route = Get-NetRoute -InterfaceAlias '{device}' "
             f"-DestinationPrefix '{prefix}' -ErrorAction SilentlyContinue; "
             "if ($route) { 'present' } else { 'absent' }")
    result = subprocess.run(["powershell.exe", "-NoProfile", "-Command", query],
                            check=True, capture_output=True, text=True, timeout=20)
    return result.stdout.strip() == "present"


def verify(app):
    if os.name != "nt" or not ctypes.windll.shell32.IsUserAnAdmin():
        raise RuntimeError("This test needs an elevated disposable Windows machine")
    address = "192.0.2.123"
    prefix = address + "/32"
    device = "XeylTest" + secrets.token_hex(3)
    token = secrets.token_hex(32)
    with tempfile.TemporaryDirectory() as folder, socket.create_server(("127.0.0.1", 0)) as listener:
        directory = Path(folder, "core")
        directory.mkdir()
        with socket.socket() as reserved:
            reserved.bind(("127.0.0.1", 0))
            api_port = reserved.getsockname()[1]
        config = {
            "mode": "rule", "log-level": "info", "ipv6": False,
            "external-controller": f"127.0.0.1:{api_port}", "secret": secrets.token_hex(32),
            "tun": {"enable": True, "device": device, "stack": "mixed", "auto-route": True,
                    "auto-detect-interface": True, "route-address": [prefix]},
            "rules": [f"IP-CIDR,{prefix},REJECT,no-resolve", "MATCH,DIRECT"],
        }
        payload = json.dumps(config).encode()
        worker = subprocess.Popen([app, "--routepilot-tun-worker", str(listener.getsockname()[1]),
                                   token, directory])
        log = directory / "mihomo.log"
        try:
            listener.settimeout(8)
            with listener.accept()[0] as lease:
                lease.settimeout(5)
                with lease.makefile("rb") as reader:
                    if not hmac.compare_digest(reader.read(64), token.encode()):
                        raise RuntimeError("Unexpected worker handshake")
                lease.sendall(struct.pack("<I", len(payload)) + payload)
                for _ in range(10):
                    if worker.poll() is not None:
                        raise RuntimeError("The TUN worker exited during startup")
                    if test_route_exists(device, prefix):
                        break
                else:
                    raise AssertionError("Windows did not install the test route")
                # Use an ordinary socket. A matching core log ties this flow to the TUN route.
                try:
                    with socket.create_connection((address, 18080), timeout=3) as client:
                        client.sendall(b"GET / HTTP/1.0\r\n\r\n")
                        client.recv(1)
                except OSError:
                    pass  # REJECT can reset the socket at connect, write or read.
                for _ in range(50):
                    if any(f"{address}:18080" in line and "REJECT" in line
                           for line in log.read_text(encoding="utf-8", errors="replace").splitlines()):
                        break
                    time.sleep(.1)
                else:
                    raise AssertionError("No REJECT decision for the test socket")
            if worker.wait(timeout=12) != 0:
                raise AssertionError("The TUN worker failed to stop")
            for _ in range(5):
                if not test_route_exists(device, prefix):
                    break
            else:
                raise AssertionError("The test route survived worker shutdown")
        except Exception:
            if log.exists():
                print(log.read_text(encoding="utf-8", errors="replace")[-3000:], file=sys.stderr)
            raise
        finally:
            if worker.poll() is None:
                try:
                    worker.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    worker.kill()
                    worker.wait(timeout=5)
    print("Windows installed the TUN route, the test socket hit REJECT, and shutdown removed the route.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(strict=True))
