"""Exercise the app-generated listeners with a real Mihomo and two loopback proxy exits."""
from contextlib import ExitStack
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from http.client import HTTPConnection
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request


class Exit(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        self.send_response_only(200)
        self.end_headers()
        # Health probes can close the tunnel before sending an HTTP request.
        line = self.rfile.readline()
        if not line.startswith(b"GET "):
            return
        while self.rfile.readline().strip():
            pass
        self.do_GET()

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(self.server.label.encode())

    def log_message(self, *args):
        pass


def check_udp(pin):
    with socket.socket(type=socket.SOCK_DGRAM) as origin, socket.socket(type=socket.SOCK_DGRAM) as client:
        origin.bind(("127.0.0.1", 0))
        origin.settimeout(3)
        client.settimeout(3)
        header = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", origin.getsockname()[1])
        client.sendto(header + b"ping", ("127.0.0.1", pin))
        data, peer = origin.recvfrom(100)
        assert data == b"ping"
        origin.sendto(b"pong", peer)
        assert client.recv(100) == header + b"pong"


def run(binary, config):
    with ExitStack() as stack:
        directory = stack.enter_context(tempfile.TemporaryDirectory())
        for node in config["proxy-providers"]["sample"]["payload"]:
            server = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Exit))
            server.label = node["name"]
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            stack.callback(server.shutdown)
            node["port"] = server.server_port
        with ExitStack() as reservations:
            ports = []
            for _ in range(5):
                sock = reservations.enter_context(socket.socket())
                sock.bind(("127.0.0.1", 0))
                ports.append(sock.getsockname()[1])
        main, pin, ctl, clash, dedicated = ports
        config["mixed-port"] = main
        config["listeners"][0]["port"] = pin
        config["external-controller"] = f"127.0.0.1:{ctl}"
        config["secret"] = "isolated-smoke"
        config["profile"] = {"store-selected": True}
        path = Path(directory, "config.json")
        client = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def api(endpoint, method="GET", data=None):
            request = urllib.request.Request(f"http://127.0.0.1:{ctl}/{endpoint}", method=method,
                headers={"Authorization": "Bearer isolated-smoke", "Content-Type": "application/json"},
                data=json.dumps(data).encode() if data else None)
            with client.open(request, timeout=4) as response:
                return response.read()

        def request(port):
            return subprocess.run(["curl", "--silent", "--show-error", "--fail", "--noproxy", "",
                "--max-time", "3", "--proxy", f"socks5h://127.0.0.1:{port}", "http://fixture.invalid/"],
                capture_output=True, text=True)

        # The dedicated inbound uses the fixed node without asking the OS for process ownership.
        # CLASH_TEST_BIN enables the extra check with a front core that can identify curl.
        authorized_clash = os.environ.get("CLASH_TEST_BIN")
        curl = Path(shutil.which("curl")).resolve()
        clash_dir = stack.enter_context(tempfile.TemporaryDirectory())
        clash_path = Path(clash_dir, "config.json")
        clash_path.write_text(json.dumps({"mixed-port": clash, "mode":"rule", "find-process-mode":"always", "log-level":"warning",
            "proxies":[{"name":"Pinned", "type":"socks5", "server":"127.0.0.1", "port":pin},
                       config["proxy-providers"]["sample"]["payload"][1]],
            "listeners":[{"name":"Pinned-in", "type":"socks", "listen":"127.0.0.1",
                          "port":dedicated, "proxy":"Pinned", "udp":True}],
            "rules":[f"PROCESS-PATH,{curl},Pinned","MATCH,US"]}))
        front = subprocess.Popen([authorized_clash or binary, "-d", clash_dir, "-f", str(clash_path)])
        stack.callback(front.wait, timeout=5)
        stack.callback(front.terminate)
        for _ in range(100):
            if front.poll() is not None:
                raise RuntimeError("The front core exited during startup")
            try:
                socket.create_connection(("127.0.0.1", dedicated), timeout=.1).close()
                break
            except OSError:
                time.sleep(.05)
        else:
            raise RuntimeError("The front core did not open the dedicated port")
        for iteration in range(2):
            path.write_text(json.dumps(config if iteration else {**config, "listeners":[]}))
            proc = subprocess.Popen([binary, "-d", directory, "-f", str(path)], stdout=subprocess.DEVNULL)
            try:
                for _ in range(100):
                    if proc.poll() is not None:
                        raise RuntimeError("Mihomo did not start")
                    try:
                        api("version")
                        break
                    except OSError:
                        time.sleep(.05)
                if not iteration:
                    api("configs?force=true", "PUT", {"payload": json.dumps(config)})
                for selected in ("JP", "US"):
                    api("proxies/GLOBAL", "PUT", {"name": selected})
                    assert request(main).stdout == selected
                    assert request(pin).stdout == "JP"
                    forwarded = request(dedicated)
                    assert forwarded.stdout == "JP", forwarded
                    if authorized_clash:
                        by_process = request(clash)
                        assert by_process.stdout == "JP", by_process
                    conn = HTTPConnection("127.0.0.1", clash, timeout=3)
                    try:
                        conn.request("GET", "http://fixture.invalid/")
                        assert conn.getresponse().read() == b"US"
                    finally:
                        conn.close()
                if iteration == 1:
                    payload = config["proxy-providers"]["sample"]["payload"]
                    payload[0] = {"name":"JP", "type":"direct"}
                    api("configs?force=true", "PUT", {"payload": json.dumps(config)})
                    check_udp(pin)
                    payload.pop(0)
                    api("configs?force=true", "PUT", {"payload": json.dumps(config)})
                    assert request(pin).returncode != 0
                    assert request(dedicated).returncode != 0
                    assert request(main).stdout == "US"
                    config["listeners"] = []
                    api("configs?force=true", "PUT", {"payload": json.dumps(config)})
                    with socket.socket() as sock:
                        assert sock.connect_ex(("127.0.0.1", pin)) != 0
            finally:
                proc.terminate()
                proc.wait(timeout=5)
    print("The Clash dedicated inbound kept its fixed exit and rejected a removed node.")
    if authorized_clash:
        print("The authorized front core also sent only the exact cURL path to the fixed exit.")


if __name__ == "__main__":
    run(sys.argv[1], json.load(sys.stdin))
