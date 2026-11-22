"""Run an isolated Windows experiment for per-application Wintun routing."""

from contextlib import contextmanager
import ctypes as c
import ipaddress
import json
from pathlib import Path
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from uuid import UUID, uuid4
from windows_routes import best_interface


class Blob(c.Structure):
    _fields_ = [("size", c.c_uint32), ("data", c.c_void_p)]


class Display(c.Structure):
    _fields_ = [("name", c.c_wchar_p), ("description", c.c_wchar_p)]


Guid = c.c_ubyte * 16


def guid(value):
    return Guid.from_buffer_copy(value.bytes_le)


class Session(c.Structure):
    _fields_ = [
        ("key", Guid), ("display", Display), ("flags", c.c_uint32), ("timeout", c.c_uint32),
        ("pid", c.c_uint32), ("sid", c.c_void_p), ("user", c.c_wchar_p), ("kernel", c.c_int32),
    ]


class Data(c.Union):
    _fields_ = [("uint32", c.c_uint32), ("pointer", c.c_void_p)]


class Value(c.Structure):
    _fields_ = [("kind", c.c_int32), ("data", Data)]


class Condition(c.Structure):
    _fields_ = [("key", Guid), ("match", c.c_int32), ("value", Value)]


class Setting(c.Structure):
    _fields_ = [("kind", c.c_int32), ("value", Value)]


class Settings(c.Structure):
    _fields_ = [("count", c.c_uint32), ("items", c.POINTER(Setting))]


class Provider(c.Structure):
    _fields_ = [
        ("key", Guid), ("display", Display), ("flags", c.c_uint32), ("provider", c.c_void_p),
        ("provider_data", Blob), ("kind", c.c_int32), ("settings", c.POINTER(Settings)),
        ("id", c.c_uint64),
    ]


def check(code, method):
    if code:
        raise OSError(f"{method} returned 0x{code & 0xffffffff:08x}")


@contextmanager
def policy(exe, luid, destination, source=None, gateway=None):
    api = c.WinDLL("fwpuclnt.dll")
    engine = c.c_void_p()
    session = Session(display=Display("Xeylroute test", None), flags=1)
    check(api.FwpmEngineOpen0(None, 10, None, c.byref(session), c.byref(engine)), "FwpmEngineOpen0")
    app = c.c_void_p()
    try:
        check(api.FwpmGetAppIdFromFileName0(c.c_wchar_p(exe), c.byref(app)), "FwpmGetAppIdFromFileName0")
        conditions = (Condition * 2)(
            Condition(guid(UUID("d78e1e87-8644-4ea5-9437-d809ecefc971")), 0, Value(12, Data(pointer=app))),
            Condition(guid(UUID("b235ae9a-1d64-49b8-a44c-5ff3d9095045")), 0,
                      Value(3, Data(uint32=int(ipaddress.IPv4Address(destination))))),
        )
        interface = c.c_uint64(luid)
        items = [Setting(1, Value(4, Data(pointer=c.addressof(interface))))]
        for kind, ip in [(0, source), (2, gateway)]:
            if ip:
                items.append(Setting(kind, Value(3, Data(uint32=int(ipaddress.IPv4Address(ip))))))
        storage = (Setting * len(items))(*items)
        settings = Settings(len(storage), storage)
        context = Provider(guid(uuid4()), Display("Xeylroute test", None), 0, None, Blob(),
                           13, c.pointer(settings), 0)
        add = api.FwpmConnectionPolicyAdd0
        add.argtypes = [c.c_void_p, c.POINTER(Provider), c.c_int32, c.c_uint64, c.c_uint32,
                        c.POINTER(Condition), c.c_void_p]
        check(add(engine, c.byref(context), 0, 1, len(conditions), conditions, None),
              "FwpmConnectionPolicyAdd0")
        yield
    finally:
        if app:
            api.FwpmFreeMemory0(c.byref(app))
        check(api.FwpmEngineClose0(engine), "FwpmEngineClose0")


def powershell(command):
    return subprocess.run(["powershell", "-NoProfile", "-NonInteractive", "-Command",
                           "$ErrorActionPreference = 'Stop'; " + command],
                          check=True, text=True, capture_output=True, timeout=20).stdout.strip()


def verify(binary):
    if not c.windll.shell32.IsUserAnAdmin():
        raise RuntimeError("The experiment requires an elevated, disposable Windows runner")
    destination = "192.0.2.163"
    prefix = destination + "/32"
    system_interface = best_interface(destination)
    device = "XeylProbe" + secrets.token_hex(3)
    curl = shutil.which("curl.exe")
    if curl is None:
        raise RuntimeError("Windows curl is unavailable")
    initial = {
        "tun": {"enable": True, "device": device, "stack": "mixed", "auto-route": False},
        "mode": "rule", "log-level": "info", "rules": [f"IP-CIDR,{prefix},REJECT,no-resolve", "MATCH,DIRECT"],
    }
    with tempfile.TemporaryDirectory() as folder:
        config = Path(folder, "probe.json")
        config.write_text(json.dumps(initial), encoding="utf-8")
        logs = Path(folder, "probe.log")
        with logs.open("wb") as output:
            core = subprocess.Popen([binary, "-d", folder, "-f", config], stdout=output, stderr=output)
        try:
            def log():
                return logs.read_text(encoding="utf-8", errors="replace")

            luid = c.c_uint64()
            ipapi = c.windll.iphlpapi
            for _ in range(60):
                if core.poll() is not None:
                    raise RuntimeError("The fixture core exited")
                if (ipapi.ConvertInterfaceAliasToLuid(c.c_wchar_p(device), c.byref(luid)) == 0
                        and "Tun adapter listening" in log()):
                    break
                time.sleep(.25)
            else:
                raise RuntimeError("The test adapter was not available")
            index = c.c_uint32()
            check(ipapi.ConvertInterfaceLuidToIndex(c.byref(luid), c.byref(index)), "ConvertInterfaceLuidToIndex")
            source = powershell(f"(Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex {index.value} | Select-Object -First 1).IPAddress")
            peer = str(ipaddress.IPv4Address(source) + 1)
            physical_peer = powershell(f"(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -InterfaceIndex {system_interface} | Select-Object -First 1).NextHop")

            def probe(stage, port):
                subprocess.run([curl, "--noproxy", "*", "--max-time", "2",
                                f"http://{destination}:{port}/"], capture_output=True, timeout=5)
                captured = f"{destination}:{port}" in log()
                print(f"{stage}: selected captured={captured}", flush=True)
                return captured

            probe("baseline", 18100)
            with policy(curl, luid.value, destination):
                without_routes = probe("interface policy", 18101)
            with policy(curl, luid.value, destination, source, peer):
                with_source = probe("interface/source/next-hop policy", 18102)

            powershell(f"New-NetRoute -DestinationPrefix '{prefix}' -InterfaceIndex {system_interface} -NextHop '{physical_peer}' -RouteMetric 1 -PolicyStore ActiveStore")
            try:
                powershell(f"New-NetRoute -DestinationPrefix '{prefix}' -InterfaceIndex {index.value} -NextHop '{peer}' -RouteMetric 9999 -PolicyStore ActiveStore")
                if best_interface(destination) != system_interface:
                    raise RuntimeError("Ordinary routing unexpectedly picked the test adapter")
                probe("both routes, no policy", 18103)
                with policy(curl, luid.value, destination, source, peer):
                    with_routes = probe("both routes, path-specific policy", 18104)
                    try:
                        socket.create_connection((destination, 18105), timeout=1).close()
                    except OSError:
                        pass
                    unselected = f"{destination}:18105" in log()
                    print(f"unselected captured={unselected}", flush=True)
                after = probe("after closing dynamic policy", 18106)
            finally:
                powershell(f"Remove-NetRoute -DestinationPrefix '{prefix}' -InterfaceIndex {index.value} -NextHop '{peer}' -PolicyStore ActiveStore -Confirm:$false -ErrorAction SilentlyContinue")
                powershell(f"Remove-NetRoute -DestinationPrefix '{prefix}' -InterfaceIndex {system_interface} -NextHop '{physical_peer}' -PolicyStore ActiveStore -Confirm:$false")
            assert not unselected and not after
            if not (without_routes or with_source or with_routes):
                raise AssertionError("No connection policy put the selected process on the tunnel")
        finally:
            core.terminate()
            core.wait(timeout=5)
            print(logs.read_text(encoding="utf-8", errors="replace")[-4000:])


if __name__ == "__main__":
    verify(Path(sys.argv[1]).resolve(strict=True))
