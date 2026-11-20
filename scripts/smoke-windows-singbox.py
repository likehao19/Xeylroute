"""Compare the pinned alternative core on a disposable Windows runner, outside the app."""
from contextlib import ExitStack
import hashlib
import json
import os
from pathlib import Path
import secrets
import select
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
    with ExitStack() as resources:
        root = Path(resources.enter_context(tempfile.TemporaryDirectory()))
        sinks = {tag: resources.enter_context(socket.create_server(("127.0.0.1", 0)))
                 for tag in ("selected", "instance", "remaining")}
        def start_client(port):
            code = ("import sys,socket; input(); "
                    f"s=socket.create_connection(('{address}',{port}),5); s.sendall(b'x'); s.recv(1)")
            child = resources.enter_context(subprocess.Popen([sys.executable, "-c", code], stdin=subprocess.PIPE,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
            resources.callback(child.kill)
            return child
        first, second = start_client(18080), start_client(18082)
        archive = root / "core.zip"
        urllib.request.urlretrieve(f"https://github.com/SagerNet/sing-box/releases/download/v1.14.4/{release}.zip", archive)
        assert hashlib.sha256(archive.read_bytes()).hexdigest() == digests[arch]
        exe = root / "sing-box.exe"
        with zipfile.ZipFile(archive) as zipped:
            exe.write_bytes(zipped.read(release + "/sing-box.exe"))
            (root / "libcronet.dll").write_bytes(zipped.read(release + "/libcronet.dll"))
        config = {"log": {"level": "debug"}, "inbounds": [{
            "type": "tun", "tag": "test", "interface_name": device, "address": ["198.18.0.1/30"],
            "auto_route": True, "route_address": [address + "/32"], "include_package": ["curl.exe"]}],
            "outbounds": [{"type": "http", "server": "127.0.0.1", "tag": tag, "server_port": sock.getsockname()[1]}
                          for tag, sock in sinks.items()],
            "route": {"rules": [{"process_name": ["curl.exe"], "action": "route", "outbound": "selected"}],
                      "final": "remaining"}}
        file = root / "config.json"
        instance_rule = {"process_name": [Path(sys.executable).name], "process_id": first.pid,
                         "action": "route", "outbound": "instance"}
        config["route"]["rules"].append(instance_rule)
        file.write_text(json.dumps(config))
        check = subprocess.run([exe, "check", "-c", file], capture_output=True, text=True, timeout=15)
        if check.returncode:
            assert "process_id" in check.stdout + check.stderr, (check.returncode, check.stdout, check.stderr)
            config["route"]["rules"].remove(instance_rule)
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
                curl = resources.enter_context(subprocess.Popen(["curl.exe", "--noproxy", "*", "--max-time", "5",
                    f"http://{address}:18081/"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))
                resources.callback(curl.kill)
                decisions = []
                for child, port in [(curl, 18081), (first, 18080), (second, 18082)]:
                    if child.stdin:
                        child.stdin.write(b"\n")
                        child.stdin.flush()
                    deadline = time.monotonic() + 10
                    while time.monotonic() < deadline:
                        ready, _, _ = select.select(list(sinks.values()), [], [], 1)
                        for marker in ready:
                            with marker.accept()[0] as conn:
                                conn.settimeout(3)
                                with conn.makefile("rb") as reader:
                                    target = reader.readline(4096).split()[:2]
                            if target == [b"CONNECT", f"{address}:{port}".encode()]:
                                decisions.append(next(tag for tag, sock in sinks.items() if sock is marker))
                                break
                        else:
                            continue
                        break
                    else:
                        raise AssertionError(f"No HTTP outlet received the test connection to {port}")
                assert decisions[0] == "selected", decisions
                print(f"sing-box 1.14.4: with include_package set to curl.exe, all three clients entered TUN. "
                      f"Outlets for curl, Python PID {first.pid} (selected instance), "
                      f"Python PID {second.pid} (other instance): {decisions}.")
            except Exception:
                relevant = [line for line in (root / "core.log").read_text(errors="replace").splitlines()
                            if address in line or "outbound/http" in line or "ERROR" in line or "WARN" in line]
                print("\n".join(relevant[-50:]), file=sys.stderr)
                raise
            finally:
                proc.terminate()
                proc.wait(timeout=8)


if __name__ == "__main__":
    verify()
