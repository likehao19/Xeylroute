"""Read the effective IPv4 egress interface using the Windows IP Helper API."""
import ctypes
import socket
import sys


def best_interface(address):
    result = ctypes.c_uint32()
    network_order = int.from_bytes(socket.inet_aton(address), sys.byteorder)
    error = ctypes.windll.iphlpapi.GetBestInterface(ctypes.c_uint32(network_order), ctypes.byref(result))
    if error:
        raise ctypes.WinError(error)
    return result.value


def uses_adapter(address, alias):
    luid = ctypes.c_uint64()
    api = ctypes.windll.iphlpapi
    if api.ConvertInterfaceAliasToLuid(ctypes.c_wchar_p(alias), ctypes.byref(luid)):
        return False
    index = ctypes.c_uint32()
    error = api.ConvertInterfaceLuidToIndex(ctypes.byref(luid), ctypes.byref(index))
    if error:
        raise ctypes.WinError(error)
    return index.value == best_interface(address)


if __name__ == "__main__":
    print(best_interface(sys.argv[1]))
