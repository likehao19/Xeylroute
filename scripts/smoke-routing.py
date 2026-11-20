"""Verify routing decisions with real local HTTP clients and an isolated bundled Mihomo."""
import json
from contextlib import ExitStack
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request


def listener(family=socket.AF_INET):
    sock = socket.socket(family)
    sock.bind(("::1" if family == socket.AF_INET6 else "127.0.0.1", 0))
    sock.listen()
    return sock


def verify(binary):
    client = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with tempfile.TemporaryDirectory() as directory, listener() as origin, listener() as other:
        with listener() as ctl, listener() as proxy:
            api_port = ctl.getsockname()[1]
            port = proxy.getsockname()[1]
        target_port = origin.getsockname()[1]
        python = str(Path(sys.executable).resolve())
        token = secrets.token_hex(24)
        rule = f"AND,((PROCESS-PATH,{python}),(DOMAIN,work.test),(DST-PORT,{target_port})),Work"
        config = {
            "mixed-port": port, "external-controller": f"127.0.0.1:{api_port}", "secret": token,
            "mode": "rule", "find-process-mode": "always", "log-level": "warning", "ipv6": True,
            "hosts": {"work.test": "127.0.0.1", "other.test": "127.0.0.1"},
            "proxy-groups": [{"name": "Work", "type": "select", "proxies": ["DIRECT"]}],
            "rules": [rule, "MATCH,DIRECT"],
        }

        def api(endpoint, method="GET", data=None):
            req = urllib.request.Request(f"http://127.0.0.1:{api_port}/{endpoint}", method=method,
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
                data=json.dumps(data).encode() if data is not None else None)
            with client.open(req, timeout=3) as response:
                return json.loads(response.read() or b"null")

        path = Path(directory, "config.json")
        path.write_text(json.dumps(config))
        proc = subprocess.Popen([binary, "-d", directory, "-f", str(path)], stdout=subprocess.DEVNULL)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    raise RuntimeError("Mihomo failed to start")
                try:
                    api("version")
                    break
                except OSError:
                    time.sleep(.05)

            def check(host, dest_port, use_curl, work, server=None):
                authority = f"[{host}]" if ":" in host else host
                url = f"http://{authority}:{dest_port}/"
                if use_curl:
                    cmd = ["curl", "--noproxy", "", "--proxy", f"http://127.0.0.1:{port}", url]
                else:
                    code = ("import socket,sys; s=socket.create_connection(('127.0.0.1',int(sys.argv[1])));"
                            "s.sendall(('GET '+sys.argv[2]+' HTTP/1.1\\r\\nHost: '+sys.argv[3]+'\\r\\n\\r\\n').encode());s.recv(1)")
                    cmd = [python, "-c", code, str(port), url, f"{authority}:{dest_port}"]
                requester = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    sock = server or (origin if dest_port == target_port else other)
                    sock.settimeout(5)
                    with sock.accept()[0]:
                        for _ in range(50):
                            connections = api("connections")["connections"] or []
                            found = [c for c in connections if host in (c["metadata"]["host"], c["metadata"].get("destinationIP"))
                                     and str(c["metadata"]["destinationPort"]) == str(dest_port)
                                     and (not use_curl or "curl" in c["metadata"].get("processPath", "").lower())]
                            if found:
                                row = found[-1]
                                assert ("Work" in row["chains"]) == work, (row["rule"], row["rulePayload"], row["chains"], row["metadata"].get("processPath"))
                                print(host, dest_port, row["rule"], row["rulePayload"], row["chains"], flush=True)
                                return row["metadata"]["processPath"]
                            time.sleep(.04)
                        else:
                            raise AssertionError("No matching live connection returned by Mihomo")
                finally:
                    if requester.poll() is None:
                        requester.terminate()
                    requester.wait(timeout=5)
                    for _ in range(50):
                        if not api("connections")["connections"]:
                            break
                        time.sleep(.02)

            config["rules"] = ["MATCH,DIRECT"]
            api("configs?force=true", "PUT", {"payload": json.dumps(config)})
            observed = check("work.test", target_port, False, False)
            config["rules"] = [rule.replace(python, observed), "MATCH,DIRECT"]
            api("configs?force=true", "PUT", {"payload": json.dumps(config)})
            check("work.test", target_port, False, True)
            # Keep two clients from the same executable alive at once. Capture each
            # local port in its own client to correlate the controller row to a PID.
            def check_instances(count):
                with ExitStack() as stack:
                    sources = {}
                    for _ in range(count):
                        code = ("import socket,sys; s=socket.create_connection(('127.0.0.1',int(sys.argv[1])));"
                                "print(s.getsockname()[1],flush=True);"
                                "s.sendall(('GET '+sys.argv[2]+' HTTP/1.0\\r\\n\\r\\n').encode());s.recv(1)")
                        child = stack.enter_context(subprocess.Popen(
                            [python, "-c", code, str(port), f"http://work.test:{target_port}/"],
                            stdout=subprocess.PIPE, text=True))
                        stack.callback(child.kill)
                        sources[child.stdout.readline().strip()] = child.pid
                        stack.enter_context(origin.accept()[0])
                    for _ in range(50):
                        connections = api("connections")["connections"] or []
                        matches = {str(c["metadata"]["sourcePort"]) for c in connections
                                   if c["metadata"]["processPath"] == observed and "Work" in c["chains"]}
                        if sources.keys() <= matches:
                            print("Executable rule matched PID(s):", *sources.values(), flush=True)
                            return
                        time.sleep(.04)
                    raise AssertionError("Executable rule did not match each identified client")

            check_instances(2)
            check_instances(1)  # A fresh process still inherits the path rule.
            check("work.test", target_port, True, False)
            check("other.test", target_port, False, False)
            check("work.test", other.getsockname()[1], False, False)
            config["rules"] = ["MATCH,DIRECT"]
            api("configs?force=true", "PUT", {"payload": json.dumps(config)})
            check("work.test", target_port, False, False)
            specific = "IP-CIDR,127.0.0.1/32,Work,no-resolve"
            local = "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve"
            for first, second, work in [(local, specific, False), (specific, local, True)]:
                config["rules"] = [first, second, "MATCH,DIRECT"]
                api("configs?force=true", "PUT", {"payload": json.dumps(config)})
                check("127.0.0.1", target_port, False, work)
            with listener(socket.AF_INET6) as ipv6:
                for prefix, work in [("::1/128", True), ("::/127", True), ("::2/127", False)]:
                    config["rules"] = [f"IP-CIDR6,{prefix},Work,no-resolve", "MATCH,DIRECT"]
                    api("configs?force=true", "PUT", {"payload": json.dumps(config)})
                    check("::1", ipv6.getsockname()[1], False, work, ipv6)
        finally:
            if proc.poll() is None:
                proc.terminate()
            proc.wait(timeout=5)


if __name__ == "__main__":
    verify(str(Path(sys.argv[1]).resolve(strict=True)))
