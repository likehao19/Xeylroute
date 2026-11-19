from pathlib import Path
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import http.server
import json
import socket
import secrets
import urllib.error
import urllib.request
import subprocess
import sys
import tempfile
import threading
import time
import zipfile

EXPECTED_SHA256 = "cd6738d4648cc1a5f48049a1343b697ab510889d648f045c5c780fc1ab443a79"


class Origin(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"routepilot-loopback-ok")

    def log_message(self, *_):
        pass


def smoke(archive_path):
    digest = hashlib.sha256(archive_path.read_bytes()).hexdigest()
    if digest != EXPECTED_SHA256:
        raise ValueError("The archive does not match the official Mihomo v1.19.34 release")
    with tempfile.TemporaryDirectory(prefix="routepilot-core-smoke-") as folder:
        trial = Path(folder)
        with zipfile.ZipFile(archive_path) as archive:
            member = next(name for name in archive.namelist() if name.lower().endswith(".exe"))
            exe = trial / "mihomo.exe"
            exe.write_bytes(archive.read(member))
        subprocess.run([exe, "-v"], check=True, creationflags=subprocess.CREATE_NO_WINDOW)
        with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin) as origin:
            threading.Thread(target=origin.serve_forever, daemon=True).start()
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                proxy_port = reservation.getsockname()[1]
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                controller_port = reservation.getsockname()[1]
            with socket.socket() as reservation:
                reservation.bind(("127.0.0.1", 0))
                probe_port = reservation.getsockname()[1]
            token = secrets.token_hex(32)
            provider_file = trial / "local.yaml"
            provider_file.write_text('{"proxies":[{"name":"Local Test Node","type":"direct"}]}')
            share_link = b"ss://YWVzLTEyOC1nY206cGFzcw@127.0.0.1:9#ShareLink"
            (trial / "link.txt").write_bytes(share_link)
            (trial / "base64.txt").write_bytes(base64.b64encode(share_link.replace(b"ShareLink", b"Base64Link")))
            profile = trial / "mihomo.json"
            config = {
                "port": proxy_port,
                "mode": "rule",
                "external-controller": f"127.0.0.1:{controller_port}",
                "secret": token,
                "allow-lan": False,
                "bind-address": "127.0.0.1",
                "proxy-groups": [{"name": "Test Selector", "type": "select", "proxies": ["DIRECT", "REJECT"]}],
                "rules": ["DOMAIN,blocked.invalid,REJECT", "MATCH,Test Selector"],
                "proxy-providers": {
                    "local": {"type": "file", "path": "./local.yaml"},
                    "link": {"type": "file", "path": "./link.txt"},
                    "base64": {"type": "file", "path": "./base64.txt"},
                },
                "listeners": [{"name": "RoutePilot-SpeedTest", "type": "http", "listen": "127.0.0.1",
                               "port": probe_port, "proxy": "Test Selector",
                               "users": [{"username": "routepilot", "password": token}]}],
            }
            profile.write_text(json.dumps(config))
            log_path = trial / "mihomo.log"
            with log_path.open("wb") as log:
                core = subprocess.Popen(
                    [exe, "-d", trial, "-f", "-"],
                    stdin=subprocess.PIPE,
                    stdout=log, stderr=subprocess.STDOUT,
                    creationflags=subprocess.CREATE_NO_WINDOW,
                )
                try:
                    with core.stdin:
                        core.stdin.write(profile.read_bytes())
                    deadline = time.monotonic() + 10
                    while True:
                        try:
                            connection = socket.create_connection(("127.0.0.1", proxy_port), timeout=1)
                            break
                        except OSError:
                            if core.poll() is not None or time.monotonic() >= deadline:
                                raise RuntimeError(log_path.read_text(errors="replace")[-2200:])
                            time.sleep(0.1)
                    with connection:
                        host = f"127.0.0.1:{origin.server_port}"
                        request = f"GET http://{host}/verify HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n"
                        connection.sendall(request.encode())
                        response = b"".join(iter(lambda: connection.recv(4096), b""))
                        assert b"200 OK" in response and b"routepilot-loopback-ok" in response, response[:400]
                    print("Real HTTP request through Mihomo to a loopback origin passed.")
                    client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    controller = f"http://127.0.0.1:{controller_port}"
                    try:
                        client.open(controller + "/configs", timeout=3)
                    except urllib.error.HTTPError as error:
                        assert error.code == 401
                    else:
                        raise AssertionError("The management endpoint accepted an unauthenticated request")

                    def controller_request(path, method="GET", data=None):
                        request = urllib.request.Request(
                            controller + path, method=method, data=data,
                            headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                        )
                        with client.open(request, timeout=3) as response:
                            payload = response.read()
                            return json.loads(payload) if payload else None

                    assert controller_request("/configs")["mode"] == "rule"
                    assert "GLOBAL" in controller_request("/proxies")["proxies"]
                    assert "connections" in controller_request("/connections")
                    rules = controller_request("/rules")["rules"]
                    assert any(rule.get("payload") == "blocked.invalid" and rule.get("proxy") == "REJECT" for rule in rules)
                    controller_request("/proxies/Test%20Selector", "PUT", b'{"name":"REJECT"}')
                    assert controller_request("/proxies/Test%20Selector")["now"] == "REJECT"
                    controller_request("/proxies/Test%20Selector", "PUT", b'{"name":"DIRECT"}')
                    controller_request("/configs", "PATCH", b'{"mode":"direct"}')
                    assert controller_request("/configs")["mode"] == "direct"
                    print("Authenticated live snapshots and a real mode change passed.")
                    assert controller_request("/providers/proxies/local")["proxies"][0]["name"] == "Local Test Node"
                    assert controller_request("/providers/proxies/link")["proxies"][0]["name"] == "ShareLink"
                    assert controller_request("/providers/proxies/base64")["proxies"][0]["name"] == "Base64Link"
                    controller_request("/providers/proxies/local", "PUT")
                    config["proxy-groups"][0]["use"] = ["local"]
                    config["mode"] = "global"
                    config["rules"] = ["MATCH,Test Selector"]
                    config["proxy-groups"].append({
                        "name": "GLOBAL", "type": "select", "proxies": ["DIRECT", "REJECT", "Test Selector"],
                        "use": ["local"],
                    })
                    controller_request("/configs?force=true", "PUT", json.dumps({"payload": json.dumps(config)}).encode())
                    assert controller_request("/configs")["mode"] == "global"
                    assert not any(rule.get("payload") == "blocked.invalid" for rule in controller_request("/rules")["rules"])
                    assert "Local Test Node" in controller_request("/proxies/GLOBAL")["all"]
                    controller_request("/proxies/GLOBAL", "PUT", b'{"name":"Local Test Node"}')
                    assert controller_request("/proxies/GLOBAL")["now"] == "Local Test Node"
                    controller_request("/configs", "PATCH", b'{"mode":"direct"}')
                    assert controller_request("/proxies/GLOBAL")["now"] == "Local Test Node"
                    controller_request("/configs", "PATCH", b'{"mode":"global"}')
                    controller_request("/proxies/GLOBAL", "PUT", b'{"name":"REJECT"}')
                    controller_request("/proxies/Test%20Selector", "PUT", b'{"name":"Local Test Node"}')
                    assert controller_request("/proxies/Test%20Selector")["now"] == "Local Test Node"

                    def probe(auth):
                        credentials = base64.b64encode(f"routepilot:{token}".encode()).decode()
                        authorization = f"Proxy-Authorization: Basic {credentials}\r\n" if auth else ""
                        with socket.create_connection(("127.0.0.1", probe_port), timeout=3) as connection:
                            connection.sendall(f"GET http://{host}/verify HTTP/1.1\r\nHost: {host}\r\n{authorization}Connection: close\r\n\r\n".encode())
                            return b"".join(iter(lambda: connection.recv(4096), b""))

                    assert b"407 Proxy Authentication Required" in probe(False)
                    assert b"routepilot-loopback-ok" in probe(True)
                    assert controller_request("/proxies/GLOBAL")["now"] == "REJECT"
                    print("Local provider refresh, live reload and independent authenticated node test route passed.")

                    def first_route_log():
                        request = urllib.request.Request(controller + "/logs?format=structured",
                                                         headers={"Authorization": f"Bearer {token}"})
                        with client.open(request, timeout=4) as response:
                            for line in response:
                                event = json.loads(line)
                                if f" --> {host} " in event["message"]:
                                    return event

                    with ThreadPoolExecutor(max_workers=1) as worker:
                        pending = worker.submit(first_route_log)
                        for _ in range(5):
                            time.sleep(0.1)
                            if pending.done():
                                break
                            probe(True)
                        assert "using" in pending.result(timeout=4)["message"]
                    print("A completed short connection was captured by the real Mihomo log stream.")
                finally:
                    if core.poll() is None:
                        core.terminate()
                    core.wait(timeout=5)
                    origin.shutdown()


if __name__ == "__main__":
    smoke(Path(sys.argv[1]))
