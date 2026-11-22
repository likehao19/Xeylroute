"""Exercise the patched core's opt-in direct failover using loopback fixtures."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time


class Origin(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"direct-origin")

    def log_message(self, *_):
        pass


class HealthyProxy(Origin):
    def do_CONNECT(self):
        if self.path != self.server.probe_authority:
            self.send_error(403)
            return
        self.send_response_only(200)
        self.end_headers()
        if self.rfile.readline().startswith(b"HEAD "):
            self.wfile.write(b"HTTP/1.0 204 No Content\r\n\r\n")


@contextmanager
def loopback_server(handler):
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def port():
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        return reservation.getsockname()[1]


@contextmanager
def core(binary, config):
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory, "config.json")
        log = Path(directory, "mihomo.log")
        path.write_text(json.dumps(config), encoding="utf-8")
        with log.open("wb") as output:
            process = subprocess.Popen([binary, "-d", directory, "-f", path], stdout=output, stderr=output)
        try:
            for _ in range(120):
                if process.poll() is not None:
                    raise RuntimeError("Mihomo exited on startup")
                try:
                    with socket.create_connection(("127.0.0.1", config["mixed-port"]), .1):
                        break
                except OSError:
                    time.sleep(.05)
            else:
                raise RuntimeError("Mihomo listener failed to start")
            yield
        except Exception:
            print(log.read_text(encoding="utf-8", errors="replace"))
            raise
        finally:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)


def verify(binary):
    with (loopback_server(Origin) as origin, loopback_server(Origin) as probe,
          loopback_server(HealthyProxy) as healthy, socket.socket() as failed):
        failed.bind(("127.0.0.1", 0))
        healthy.probe_authority = f"127.0.0.1:{probe.server_port}"
        check = f"http://{healthy.probe_authority}/health"

        def assert_request(listener, success, host="127.0.0.1"):
            result = subprocess.run(["curl", "--silent", "--show-error", "--fail", "--max-time", "15",
                                     "--noproxy", "", "--proxy", f"http://127.0.0.1:{listener}",
                                     f"http://{host}:{origin.server_port}/resource"], capture_output=True, timeout=17)
            if success:
                assert result.returncode == 0 and result.stdout == b"direct-origin", result
            else:
                assert result.returncode != 0 and b"direct-origin" not in result.stdout, result

        def config(mode, outbound, enabled):
            regular, pinned = port(), port()
            while pinned == regular:
                pinned = port()
            return {
                "mixed-port": regular, "mode": mode,
                "routepilot-fallback-probe": check if enabled else "",
                "hosts": {"blocked.routepilot.test": "127.0.0.1"},
                "proxies": [
                    {"name": "Unavailable", "type": "http", "server": "127.0.0.1", "port": failed.getsockname()[1]},
                    {"name": "Healthy", "type": "http", "server": "127.0.0.1", "port": healthy.server_port},
                ],
                "proxy-groups": [
                    {"name": "GLOBAL", "type": "select", "proxies": [outbound]},
                    {"name": "Blocked", "type": "select", "proxies": ["REJECT"]},
                ],
                "rules": ["DOMAIN,blocked.routepilot.test,Blocked", f"MATCH,{outbound}"],
                "listeners": [{"name": "fixed", "type": "http", "listen": "127.0.0.1",
                               "port": pinned, "proxy": "Unavailable"}],
            }

        for mode, outbound, enabled, success in [
            ("rule", "Unavailable", False, False),
            ("rule", "Unavailable", True, True),
            ("global", "Unavailable", True, True),
            ("rule", "Healthy", True, False),
        ]:
            settings = config(mode, outbound, enabled)
            with core(binary, settings):
                assert_request(settings["mixed-port"], success)
                if mode == "rule" and success:
                    assert_request(settings["mixed-port"], False, "blocked.routepilot.test")
                    assert_request(settings["listeners"][0]["port"], False)
    print("Direct fallback is opt-in and passes in rule and global modes. A healthy exit, explicit reject and a pinned listener never fall back.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(strict=True))
