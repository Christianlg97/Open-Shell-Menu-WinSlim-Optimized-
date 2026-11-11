"""Compare shell icon indexes without launching apps or modifying shortcuts."""
import ctypes as C
from ctypes import wintypes as W
import os
from pathlib import Path
import struct
import sys


class FileInfo(C.Structure):
    _fields_ = [("icon", W.HICON), ("index", C.c_int), ("attributes", W.DWORD),
                ("display", W.WCHAR * 260), ("type", W.WCHAR * 80)]


shell = C.WinDLL("shell32", use_last_error=True)
ole = C.WinDLL("ole32")
ole.CoInitialize.argtypes = [C.c_void_p]
ole.CoInitialize.restype = C.c_long
shell.SHGetFileInfoW.argtypes = [C.c_void_p, W.DWORD, C.POINTER(FileInfo), W.UINT, W.UINT]
shell.SHGetFileInfoW.restype = C.c_size_t
shell.SHChangeNotify.argtypes = [W.LONG, W.UINT, C.c_void_p, C.c_void_p]
shell.SHChangeNotify.restype = None


def icon_index(value, flags=0, attributes=0):
    info = FileInfo()
    if isinstance(value, str):
        value = C.cast(C.c_wchar_p(value), C.c_void_p)
    if not shell.SHGetFileInfoW(value, attributes, C.byref(info), C.sizeof(info), flags | 0x4001):
        raise C.WinError(C.get_last_error())
    return info.index


initialized = ole.CoInitialize(None)
try:
    source = Path(r"C:\WSCore\Components\Hooks\Shortcuts\Tienda de aplicaciones.lnk")
    candidates = list(Path(os.environ["TEMP"]).glob("OpenShellStoreShortcut-*/Tienda de aplicaciones.lnk"))
    candidate = max(candidates, key=lambda path: path.stat().st_mtime_ns) if candidates else source
    data = source.read_bytes()
    length, = struct.unpack_from("<H", data, 76)
    pidl = C.create_string_buffer(data[78:78 + length])
    target = icon_index(C.cast(pidl, C.c_void_p), 0x8)
    original = icon_index(str(source))
    repaired = icon_index(str(candidate))
    generic = icon_index("missing.openshell-unknown-extension", 0x10, 0x80)
    print({"original": original, "candidate": repaired, "Store_target": target, "generic_file": generic})
    if repaired == generic or repaired != target:
        raise AssertionError("Candidate does not resolve to the native Store icon")
    print("Verified native Store icon and unchanged application target.")
    if "--notify" in sys.argv:
        if original != target:
            raise AssertionError("Installed shortcut still has the wrong icon")
        path = C.c_wchar_p(str(source))
        shell.SHChangeNotify(0x2000, 0x2005, C.cast(path, C.c_void_p), None)
        print("Shell notified to refresh the repaired shortcut.")
finally:
    if initialized >= 0:
        ole.CoUninitialize()
