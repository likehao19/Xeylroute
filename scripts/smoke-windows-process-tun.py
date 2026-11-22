"""Verify selected traffic enters the TUN stack and bypassed traffic leaves Windows."""

from contextlib import contextmanager
import ctypes as c
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import shutil
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
import winreg
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


class SocksUdp(socketserver.StreamRequestHandler):
    def handle(self):
        greeting = self.rfile.read(2)
        if len(greeting) != 2 or greeting[0] != 5 or b"\0" not in self.rfile.read(greeting[1]):
            return
        self.wfile.write(b"\x05\x00")
        request = self.rfile.read(4)
        if len(request) != 4 or request[:3] != b"\x05\x03\x00":
            return
        self.rfile.read(18 if request[3] == 4 else 6)
        with socket.socket(type=socket.SOCK_DGRAM) as relay:
            relay.bind(("127.0.0.1", 0))
            relay.settimeout(3)
            self.wfile.write(b"\x05\x00\x00\x01" + socket.inet_aton("127.0.0.1")
                             + relay.getsockname()[1].to_bytes(2, "big"))
            packet, client = relay.recvfrom(1024)
            if packet[3:8] == b"\x01" + socket.inet_aton(DEST) and packet[10:] == b"request":
                relay.sendto(packet[:10] + b"selected udp", client)
                self.connection.settimeout(2)
                try:
                    self.rfile.read(1)
                except TimeoutError:
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
    # Sniff only. The observer must never load the driver image from the install directory.
    handle = driver.WinDivertOpen(expression.encode(), 0, -100, 1 | 4 | 16)
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


def queued_driver_files():
    with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, r"SYSTEM\CurrentControlSet\Control\Session Manager") as key:
        query = c.windll.advapi32.RegQueryValueExW
        query.argtypes = [c.c_void_p, c.c_wchar_p, c.c_void_p, c.c_void_p, c.c_void_p, c.POINTER(c.c_uint32)]
        query.restype = c.c_long
        size = c.c_uint32()
        value = "PendingFileRenameOperations"
        handle = c.c_void_p(int(key))
        result = query(handle, value, None, None, None, c.byref(size))
        if result == 2:  # ERROR_FILE_NOT_FOUND
            return set()
        if result:
            raise c.WinError(result)
        data = (c.c_ubyte * size.value)()
        result = query(handle, value, None, None, data, c.byref(size))
        if result:
            raise c.WinError(result)
    # Empty destinations encode deletion. Read the raw value to preserve those entries.
    moves = bytes(data[:size.value]).decode("utf-16-le").casefold().split("\0")
    return {path for path, destination in zip(moves[::2], moves[1::2])
            if not destination and "\\system32\\drivers\\xeylroute-" in path
            and path.endswith("\\windivert64.sys")}


def verify(binary):
    if not c.windll.shell32.IsUserAnAdmin():
        raise RuntimeError("Run on an elevated, disposable Windows runner")
    original = best_interface(DEST)
    with (tempfile.TemporaryDirectory() as folder,
          ThreadingHTTPServer(("127.0.0.1", 0), Proxy) as origin,
          socketserver.ThreadingTCPServer(("127.0.0.1", 0), SocksUdp) as udp):
        for server in (origin, udp):
            threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            log = Path(folder, "selected.log")
            config = Path(folder, "selected.json")
            config.write_text(json.dumps({
                "mode": "rule", "log-level": "info",
                "tun": {"enable": True, "auto-route": False, "auto-detect-interface": False,
                        "stack": "gvisor", "windows-process-capture": True,
                        "windows-process-paths": [instance_image()]},
                "proxies": [{"name": "SelectedExit", "type": "http", "server": "127.0.0.1",
                             "port": origin.server_port},
                            {"name": "SelectedUdp", "type": "socks5", "server": "127.0.0.1",
                             "port": udp.server_address[1], "udp": True}],
                "rules": [f"AND,((IP-CIDR,{DEST}/32,no-resolve),(NETWORK,UDP)),SelectedUdp",
                          f"IP-CIDR,{DEST}/32,SelectedExit,no-resolve", "MATCH,DIRECT"],
            }), encoding="utf-8")
            pending_before = queued_driver_files()
            with log.open("wb") as output:
                core = subprocess.Popen([binary, "-d", folder, "-f", config], stdout=output, stderr=output)
            try:
                for _ in range(100):
                    if core.poll() is not None:
                        raise RuntimeError("Mihomo exited")
                    logged = log.read_text(encoding="utf-8", errors="replace")
                    if "Tun adapter listening" in logged and "Start initial compatible provider default" in logged:
                        break
                    time.sleep(.05)
                else:
                    raise RuntimeError("Selected software TUN did not start")
                assert queued_driver_files() - pending_before, "Running driver image has no queued restart cleanup"
                with observe_physical_packets(binary.with_name("WinDivert.dll")) as physical:
                    assert best_interface(DEST) == original
                    response = request_selected(TARGET)
                    assert response.endswith(b"selected"), (response, physical)
                    with socket.socket(type=socket.SOCK_DGRAM) as datagram:
                        datagram.settimeout(4)
                        datagram.sendto(b"request", (DEST, TARGET))
                        assert datagram.recvfrom(1024) == (b"selected udp", (DEST, TARGET))
                    curl = shutil.which("curl.exe")
                    subprocess.run([curl, "--noproxy", "*", "--max-time", "2", f"http://{DEST}:{BYPASS}/"],
                                   capture_output=True, timeout=4)
                    assert physical.get(BYPASS) == original, physical
                    assert TARGET not in physical, physical
                    logged = log.read_text(encoding="utf-8", errors="replace")
                    assert f"{DEST}:{TARGET}" in logged and "using SelectedExit" in logged, logged
                    assert f"{DEST}:{BYPASS}" not in logged
                    core.terminate()
                    core.wait(timeout=5)
                    try:
                        request_selected(AFTER)
                    except OSError:
                        pass
                    assert best_interface(DEST) == original
                    assert physical.get(AFTER) == original, physical
            except Exception:
                print(log.read_text(encoding="utf-8", errors="replace"))
                raise
            finally:
                if core.poll() is None:
                    core.terminate()
                    core.wait(timeout=5)
        finally:
            origin.shutdown()
            udp.shutdown()
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
