"""GDI cache regression: row order, alpha and selected sources; no files or builds."""
import ctypes as C
from ctypes import wintypes as W


class Header(C.Structure):
    _fields_ = [("size", W.DWORD), ("width", W.LONG), ("height", W.LONG),
                ("planes", W.WORD), ("bpp", W.WORD), ("compression", W.DWORD),
                ("bytes", W.DWORD), ("xppm", W.LONG), ("yppm", W.LONG),
                ("used", W.DWORD), ("important", W.DWORD)]


class Info(C.Structure):
    _fields_ = [("header", Header), ("colors", W.DWORD * 1)]


class Bitmap(C.Structure):
    _fields_ = [("type", W.LONG), ("width", W.LONG), ("height", W.LONG),
                ("stride", W.LONG), ("planes", W.WORD), ("bpp", W.WORD),
                ("bits", C.c_void_p)]


class DibSection(C.Structure):
    _fields_ = [("bitmap", Bitmap), ("header", Header), ("masks", W.DWORD * 3),
                ("section", W.HANDLE), ("offset", W.DWORD)]


def probe(top_down, selected=False, width=2, height=3):
    gdi = C.WinDLL("gdi32", use_last_error=True)
    user = C.WinDLL("user32", use_last_error=True)
    gdi.CreateCompatibleDC.argtypes = [W.HDC]
    gdi.CreateCompatibleDC.restype = W.HDC
    gdi.CreateDIBSection.argtypes = [W.HDC, C.POINTER(Info), W.UINT, C.POINTER(C.c_void_p), W.HANDLE, W.DWORD]
    gdi.CreateDIBSection.restype = W.HBITMAP
    gdi.GetObjectW.argtypes = [W.HANDLE, C.c_int, C.c_void_p]
    gdi.GetObjectW.restype = C.c_int
    gdi.GetDIBits.argtypes = [W.HDC, W.HBITMAP, W.UINT, W.UINT, C.c_void_p, C.POINTER(Info), W.UINT]
    gdi.GetDIBits.restype = C.c_int
    user.CopyImage.argtypes = [W.HANDLE, W.UINT, C.c_int, C.c_int, W.UINT]
    user.CopyImage.restype = W.HANDLE
    gdi.SelectObject.argtypes = [W.HDC, W.HANDLE]
    gdi.SelectObject.restype = W.HANDLE
    gdi.DeleteObject.argtypes = [W.HANDLE]
    gdi.DeleteDC.argtypes = [W.HDC]
    info = Info()
    info.header = Header(C.sizeof(Header), width, -height if top_down else height, 1, 32)
    pixels = C.c_void_p()
    dc = gdi.CreateCompatibleDC(None)
    bitmap = gdi.CreateDIBSection(dc, C.byref(info), 0, C.byref(pixels), None, 0)
    if not dc or not bitmap or not pixels.value:
        error = C.get_last_error()
        if bitmap:
            gdi.DeleteObject(bitmap)
        if dc:
            gdi.DeleteDC(dc)
        raise C.WinError(error)
    original_selection = None
    snapshot = None
    restored = None
    try:
        logical_rows = [tuple(((128 + y % 128) << 24) | (((y + 1) % 128) << 16) |
                              (((x + 1) % 128) << 8) | ((x + y + 1) % 128)
                              for x in range(width)) for y in range(height)]
        physical_rows = logical_rows if top_down else logical_rows[::-1]
        physical = [pixel for row in physical_rows for pixel in row]
        pixel_type = W.DWORD * (width * height)
        C.memmove(pixels, pixel_type(*physical), width * height * 4)
        section = DibSection()
        if gdi.GetObjectW(bitmap, C.sizeof(section), C.byref(section)) != C.sizeof(section):
            raise C.WinError(C.get_last_error())
        old = []
        for row in range(height):
            source_row = height - 1 - row if section.header.height < 0 else row
            old.extend(physical_rows[source_row])
        output = pixel_type()
        info.header.height = height
        if gdi.GetDIBits(dc, bitmap, 0, height, output, C.byref(info), 0) != height:
            raise C.WinError(C.get_last_error())
        expected = [pixel for row in logical_rows[::-1] for pixel in row]
        assert list(output) == expected, "GDI did not preserve the visible row order"
        if selected:
            original_selection = gdi.SelectObject(dc, bitmap)
            if not original_selection or original_selection == C.c_void_p(-1).value:
                raise C.WinError(C.get_last_error())
        snapshot = user.CopyImage(bitmap, 0, width, height, 0x2000)  # IMAGE_BITMAP, LR_CREATEDIBSECTION
        if not snapshot or snapshot == bitmap:
            raise AssertionError("Snapshot must own a separate bitmap")
        info.header.height = height
        if gdi.GetDIBits(dc, snapshot, 0, height, output, C.byref(info), 0) != height:
            raise C.WinError(C.get_last_error())
        normalized = list(output)
        assert normalized == expected, "Snapshot changed row order or alpha bytes"
        restored_pixels = C.c_void_p()
        restored = gdi.CreateDIBSection(dc, C.byref(info), 0, C.byref(restored_pixels), None, 0)
        if not restored or not restored_pixels.value:
            raise C.WinError(C.get_last_error())
        C.memmove(restored_pixels, output, width * height * 4)
        info.header.height = -height
        if gdi.GetDIBits(dc, restored, 0, height, output, C.byref(info), 0) != height:
            raise C.WinError(C.get_last_error())
        logical = [pixel for row in logical_rows for pixel in row]
        assert list(output) == logical, "Cache reload inverted pixels or alpha"
        return {"top_down": top_down, "selected_in_dc": selected, "reported_height": section.header.height,
                "old_snapshot_matches": old == expected, "normalized_snapshot_matches": normalized == expected,
                "cache_round_trip_matches": list(output) == logical}
    finally:
        if restored:
            gdi.DeleteObject(restored)
        if snapshot:
            gdi.DeleteObject(snapshot)
        if original_selection:
            gdi.SelectObject(dc, original_selection)
        gdi.DeleteObject(bitmap)
        gdi.DeleteDC(dc)


if __name__ == "__main__":
    results = []
    for width, height in ((2, 3), (16, 16), (32, 32), (48, 48), (128, 128)):
        for top_down in (False, True):
            for selected in (False, True):
                results.append(probe(top_down, selected, width, height))
    print(f"Bitmap cache: {len(results)} GDI round trips passed (row order, alpha and selected sources).")
