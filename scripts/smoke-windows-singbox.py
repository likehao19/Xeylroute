"""Compare the pinned alternative core on a disposable Windows runner, outside the app."""
import copy
import hashlib
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from windows_routes import uses_adapter


def verify():
    if os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or os.name != "nt":
        raise RuntimeError("Use a disposable Windows runner")
    arch = {"X64": "amd64", "ARM64": "arm64"}[os.environ["RUNNER_ARCH"]]
    digests = {"amd64": "99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df",
               "arm64": "8cd0a4d0cd8cd480be5731ac31f17038969a42d12add9feb6e031fd43d85bbae"}
    release = f"sing-box-1.14.4-windows-{arch}"
    address = "192.0.2.123"
    device = "XeylAlt" + secrets.token_hex(3)
    with tempfile.TemporaryDirectory() as temp, socket.create_server(("127.0.0.1", 0)) as a, socket.create_server(("127.0.0.1", 0)) as b:
        root = Path(temp)
        archive = root / "core.zip"
        urllib.request.urlretrieve(f"https://github.com/SagerNet/sing-box/releases/download/v1.14.4/{release}.zip", archive)
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == digests[arch]
        exe = root / "sing-box.exe"
        with zipfile.ZipFile(archive) as zipped:
            exe.write_bytes(zipped.read(release + "/sing-box.exe"))
        config = {"log": {"level": "debug"}, "inbounds": [{
            "type": "tun", "tag": "test", "interface_name": device, "address": ["198.18.0.1/30"],
            "auto_route": True, "route_address": [address + "/32"], "include_package": ["curl.exe"]}],
            "outbounds": [{"type": "http", "server": "127.0.0.1", "tag": tag, "server_port": sock.getsockname()[1]}
                          for tag, sock in [("selected", a), ("remaining", b)]],
            "route": {"rules": [{"process_name": ["curl.exe"], "action": "route", "outbound": "selected"}],
                      "final": "remaining"}}
        file = root / "config.json"
        pid_config = copy.deepcopy(config)
        pid_config["route"]["rules"][0] = {"process_id": os.getpid(), "action": "reject"}
        file.write_text(json.dumps(pid_config))
        check = subprocess.run([exe, "check", "-c", file], capture_output=True, text=True, timeout=15)
        assert check.returncode and "process_id" in (check.stdout + check.stderr), check.stderr
        file.write_text(json.dumps(config))
        with (root / "core.log").open("w") as log:
            proc = subprocess.Popen([exe, "run", "-c", file], stdout=log, stderr=log)
            try:
                # Wait for the OS route before originating traffic from either client.
                for _ in range(120):
                    if proc.poll() is not None:
                        raise RuntimeError((root / "core.log").read_text(errors="replace"))
                    if uses_adapter(address, device):
                        break
                    time.sleep(.25)
                else:
                    raise AssertionError("Missing test route")
                for client, marker, port in [("curl", a, 18081), ("python", b, 18080)]:
                    cmd = (["curl.exe", "--noproxy", "*", "--max-time", "5", f"http://{address}:{port}/"]
                           if client == "curl" else [sys.executable, "-c",
                           f"import socket; s=socket.create_connection(('{address}',{port}),5); s.sendall(b'x'); s.recv(1)"])
                    with subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as child:
                        try:
                            marker.settimeout(8)
                            with marker.accept()[0] as conn:
                                conn.settimeout(5)
                                with conn.makefile("rb") as reader:
                                    assert reader.readline(4096).split()[:2] == [b"CONNECT", f"{address}:{port}".encode()]
                        finally:
                            child.kill()
                print("sing-box 1.14.4: both apps entered TUN with include_package set;"
                      " curl and Python used different exits. process_id was rejected.")
            except Exception:
                print((root / "core.log").read_text(errors="replace")[-3000:], file=sys.stderr)
                raise
            finally:
                proc.terminate()
                proc.wait(timeout=8)


if __name__ == "__main__":
    verify()
