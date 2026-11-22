"""Verify selected traffic enters the TUN stack and bypassed traffic leaves Windows."""

from contextlib import contextmanager
import ctypes as c
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from windows_routes import best_interface


DEST = "192.0.2.137"
TARGET, BYPASS, AFTER = 18123, 18124, 18125


class Proxy(BaseHTTPRequestHandler):
    def do_CONNECT(self):
        self.send_response_only(200)
        self.end_headers()
        if self.rfile.readline().startswith(b"GET "):
            self.wfile.write(b"HTTP/1.0 200 OK\r\nContent-Length: 8\r\n\r\nselected")

    def log_message(self, *_):
        pass


@contextmanager
def observe_physical_packets(driver_path):
    driver = c.WinDLL(str(driver_path), use_last_error=True)
    driver.WinDivertOpen.argtypes = [c.c_char_p, c.c_int, c.c_int16, c.c_uint64]
    driver.WinDivertOpen.restype = c.c_void_p
    driver.WinDivertClose.argtypes = [c.c_void_p]
    driver.WinDivertShutdown.argtypes = [c.c_void_p, c.c_int]
    driver.WinDivertRecv.argtypes = [c.c_void_p, c.c_void_p, c.c_uint32, c.POINTER(c.c_uint32), c.c_void_p]
    expression = f"outbound and ip.DstAddr == {DEST} and tcp.Syn and tcp.DstPort >= {TARGET} and tcp.DstPort <= {AFTER}"
    handle = driver.WinDivertOpen(expression.encode(), 0, -100, 1 | 4)
    if handle == c.c_void_p(-1).value:
        raise c.WinError(c.get_last_error())
    seen = {}

    def sample():
        buffer = (c.c_ubyte * 65576)()
        address = (c.c_uint64 * 10)()
        size = c.c_uint32()
        while driver.WinDivertRecv(handle, buffer, len(buffer), c.byref(size), address):
            tcp = (buffer[0] & 15) * 4
            port = (buffer[tcp+2] << 8) | buffer[tcp+3]
            interface = address[2] & 0xffffffff
            seen[port] = interface

    thread = threading.Thread(target=sample, daemon=True)
    thread.start()
    try:
        yield seen
    finally:
        driver.WinDivertShutdown(handle, 1)
        thread.join(timeout=5)
        driver.WinDivertClose(handle)


def request_selected(port):
    with socket.create_connection((DEST, port), timeout=3) as connection:
        connection.sendall(b"GET / HTTP/1.0\r\nHost: fixture.test\r\n\r\n")
        message = b"".join(iter(lambda: connection.recv(1024), b""))
    return message


def verify(binary):
    if not c.windll.shell32.IsUserAnAdmin():
        raise RuntimeError("Run on an elevated, disposable Windows runner")
    original = best_interface(DEST)
    with tempfile.TemporaryDirectory() as folder, ThreadingHTTPServer(("127.0.0.1", 0), Proxy) as origin:
        thread = threading.Thread(target=origin.serve_forever, daemon=True)
        thread.start()
        try:
            log = Path(folder, "selected.log")
            config = Path(folder, "selected.json")
            config.write_text(json.dumps({
                "mode": "rule", "log-level": "info",
                "tun": {"enable": True, "auto-route": False, "auto-detect-interface": False,
                        "stack": "gvisor", "windows-process-capture": True,
                        "windows-process-paths": [instance_image()]},
                "proxies": [{"name": "SelectedExit", "type": "http", "server": "127.0.0.1",
                             "port": origin.server_port}],
                "rules": [f"IP-CIDR,{DEST}/32,SelectedExit,no-resolve", "MATCH,DIRECT"],
            }), encoding="utf-8")
            with observe_physical_packets(binary.with_name("WinDivert.dll")) as physical:
                with log.open("wb") as output:
                    core = subprocess.Popen([binary, "-d", folder, "-f", config], stdout=output, stderr=output)
                try:
                    for _ in range(100):
                        if core.poll() is not None:
                            raise RuntimeError("Mihomo exited")
                        if "Tun adapter listening" in log.read_text(encoding="utf-8", errors="replace"):
                            break
                        time.sleep(.05)
                    else:
                        raise RuntimeError("Selected software TUN did not start")
                    assert best_interface(DEST) == original
                    assert request_selected(TARGET).endswith(b"selected")
                    curl = shutil.which("curl.exe")
                    subprocess.run([curl, "--noproxy", "*", "--max-time", "2", f"http://{DEST}:{BYPASS}/"],
                                   capture_output=True, timeout=4)
                    assert physical.get(BYPASS) == original, physical
                    assert TARGET not in physical, physical
                    logged = log.read_text(encoding="utf-8", errors="replace")
                    assert f"{DEST}:{TARGET}" in logged and "using SelectedExit" in logged, logged
                    assert f"{DEST}:{BYPASS}" not in logged
                except Exception:
                    print(log.read_text(encoding="utf-8", errors="replace"))
                    raise
                finally:
                    core.terminate()
                    core.wait(timeout=5)
                try:
                    request_selected(AFTER)
                except OSError:
                    pass
                assert best_interface(DEST) == original
                assert physical.get(AFTER) == original, physical
        finally:
            origin.shutdown()
    print("Only the selected executable entered TUN, another executable stayed on its original interface, and shutdown restored the selected executable.")


def instance_image():
    api = c.windll.kernel32
    api.GetCurrentProcess.restype = c.c_void_p
    name = c.create_unicode_buffer(32768)
    size = c.c_uint32(len(name))
    if not api.QueryFullProcessImageNameW(c.c_void_p(api.GetCurrentProcess()), 0, name, c.byref(size)):
        raise c.WinError()
    return name.value


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(strict=True))
