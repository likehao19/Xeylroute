"""Check that real Mihomo TCP connections select the exact Windows process."""

import base64
from contextlib import ExitStack
import ctypes as c
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
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"origin")

    def log_message(self, *_):
        pass


CLIENT = """+import socket, sys
for command in sys.stdin:
    proxy, origin = map(int, command.split())
    try:
        with socket.create_connection(("127.0.0.1", proxy), timeout=2) as s:
            s.sendall(f"GET http://127.0.0.1:{origin}/ HTTP/1.0\r\n\r\n".encode())
            data = s.recv(100)
            result = data.startswith(b"HTTP/1.1 200") or data.startswith(b"HTTP/1.0 200")
    except OSError:
        result = False
    print(int(result), flush=True)
"""


def instance(pid):
    api = c.windll.kernel32
    api.OpenProcess.restype = c.c_void_p
    raw = api.OpenProcess(0x1000, False, pid)
    if not raw:
        raise c.WinError()
    handle = c.c_void_p(raw)
    try:
        times = (c.c_uint64 * 4)()
        if not api.GetProcessTimes(handle, *(c.byref(times, 8*i) for i in range(4))):
            raise c.WinError()
        name = c.create_unicode_buffer(32768)
        size = c.c_uint32(len(name))
        if not api.QueryFullProcessImageNameW(handle, 0, name, c.byref(size)):
            raise c.WinError()
        return pid, times[0], name.value
    finally:
        api.CloseHandle(handle)


def client(stack):
    worker = stack.enter_context(subprocess.Popen([sys.executable, "-u", "-c", CLIENT],
                                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                                   text=True))
    stack.callback(worker.terminate)
    return worker


def verify(binary):
    with ExitStack() as stack:
        origin = stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Origin))
        thread = threading.Thread(target=origin.serve_forever, daemon=True)
        thread.start()
        stack.callback(origin.shutdown)
        selected = client(stack)
        unselected = client(stack)
        pid, started, path = instance(selected.pid)
        assert path == instance(unselected.pid)[2]
        directory = stack.enter_context(tempfile.TemporaryDirectory())
        config = Path(directory, "process.json")
        log = Path(directory, "mihomo.log")

        def try_profile(identity, selected_should_pass):
            with socket.socket() as reserve:
                reserve.bind(("127.0.0.1", 0))
                port = reserve.getsockname()[1]
            target_pid, target_started, target_path = identity
            escaped = base64.urlsafe_b64encode(target_path.encode()).decode().rstrip("=")
            config.write_text(json.dumps({
                "mixed-port": port, "mode": "rule", "log-level": "info",
                "bind-address": "127.0.0.1", "find-process-mode": "always",
                "rules": [f"PROCESS-INSTANCE,{target_pid}:{target_started}:{escaped},REJECT", "MATCH,DIRECT"],
            }), encoding="utf-8")
            with log.open("wb") as stream:
                core = subprocess.Popen([binary, "-d", directory, "-f", config], stdout=stream, stderr=stream)
            try:
                for _ in range(100):
                    if core.poll() is not None:
                        raise RuntimeError("Mihomo exited during initialization")
                    try:
                        socket.create_connection(("127.0.0.1", port), timeout=.1).close()
                        break
                    except OSError:
                        time.sleep(.05)
                else:
                    raise RuntimeError("Mihomo did not listen")
                for worker, should_pass in [(selected, selected_should_pass), (unselected, True)]:
                    worker.stdin.write(f"{port} {origin.server_port}\n")
                    worker.stdin.flush()
                    result = worker.stdout.readline().strip()
                    assert result == str(int(should_pass)), (worker.pid, result, should_pass)
                if not selected_should_pass:
                    assert "match ProcessInstance" in log.read_text(encoding="utf-8", errors="replace")
            except Exception:
                print(log.read_text(encoding="utf-8", errors="replace"))
                raise
            finally:
                core.terminate()
                core.wait(timeout=5)

        try_profile((pid, started, path), False)
        try_profile((pid, started - 1, path), True)
        try_profile((pid, started, path + ".old"), True)
        selected.terminate()
        selected.wait(timeout=5)
        selected = client(stack)
        try_profile((pid, started, path), True)
    print("Only the selected PID, creation time and executable combination was rejected.")


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(strict=True))
