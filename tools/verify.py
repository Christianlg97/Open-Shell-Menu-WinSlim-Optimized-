"""Read-only source/config checks and isolated Win32 regressions; never builds."""
from pathlib import Path
import ctypes as C
import re
import subprocess
import sys
import tomllib
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]


def source(name):
    return (ROOT / name).read_text(encoding="utf-8-sig")


def function_body(text, signature, following):
    return text[text.index(signature):text.index(following, text.index(signature))]


class SourceRegressions(unittest.TestCase):
    def test_project_xml_and_rust_manifest(self):
        for extension in ("*.vcxproj", "*.props", "*.targets", "*.wxs"):
            for path in (ROOT / "Src").rglob(extension):
                with self.subTest(path=path):
                    ET.parse(path)
        ET.parse(ROOT / "tools/CoreTests.vcxproj")
        manifest = tomllib.loads(source("Src/RustCore/Cargo.toml"))
        self.assertIn("staticlib", manifest["lib"]["crate-type"])
        self.assertEqual(manifest["profile"]["release"]["panic"], "unwind")

    def test_profile_keys_are_registered_and_unique(self):
        profile = ROOT.parent / "WinSlim Profile/Menu Settings.xml"
        if not profile.exists():
            self.skipTest("External WinSlim profile is not in this checkout")
        settings = ET.parse(profile).getroot()
        registered = set(re.findall(r'\{L"([^"]+)"', source("Src/StartMenu/StartMenuDLL/SettingsUI.cpp")))
        names = [item.tag for item in settings]
        self.assertEqual(settings.get("component"), "StartMenu")
        self.assertEqual(len(names), len(set(names)))
        self.assertFalse(set(names) - registered)

    def test_no_hresult_check_on_bool_shell_api(self):
        for path in (ROOT / "Src").rglob("*.cpp"):
            self.assertNotRegex(path.read_text(encoding="utf-8-sig", errors="replace"), r"(?:SUCCEEDED|FAILED)\(SHGetPathFromIDList\(", str(path))

    def test_clear_cache_preserves_borrowed_objects(self):
        text = source("Src/StartMenu/StartMenuDLL/ItemManager.cpp")
        clear = function_body(text, "void CItemManager::ClearCache(", "int CItemManager::GetIconSize(")
        self.assertNotIn(".clear()", clear)
        self.assertNotIn("DeleteObject", clear)
        self.assertNotIn("WaitFor", clear)
        self.assertIn("m_bCacheDisabled.store(true)", clear)
        queue = function_body(text, "void CItemManager::QueueItemInfo(", "void CItemManager::WaitForShortcuts(")
        self.assertNotIn("for (", queue)
        self.assertIn("queued=true", queue)
        self.assertIn("pItemInfo->queuedHigh=false", text)
        self.assertIn("pItemInfo->queuedLow=false", text)
        self.assertIn("WinSlimValidatePidl", text)
        self.assertIn("WinSlimBitmapBytes", text)

    def test_location_does_not_wait_or_transfer_context_menu(self):
        text = source("Src/StartMenu/StartMenuDLL/MenuCommands.cpp")
        self.assertNotIn("ExecuteOnSTAThread", text)
        self.assertNotIn("worker.join()", text)
        self.assertIn("QueueOpenFolder(pItemPidl1,true)", text)
        self.assertIn("link->GetIDList(&target)", text)
        request = function_body(text, "struct OpenFolderRequest", "static DWORD WINAPI OpenFolderWorker")
        self.assertNotIn("IContextMenu", request)
        self.assertIn("FreeLibraryAndExitThread(module", text)

    def test_search_closes_event_and_calls_core(self):
        text = source("Src/StartMenu/StartMenuDLL/SearchManager.cpp")
        self.assertIn("CloseHandle(m_ExitEvent)", text)
        self.assertIn("WinSlimMatchText(", text)
        self.assertIn("std::map<std::pair<std::wstring,bool>,NameGroup>", text)

    def test_update_signature_is_mandatory(self):
        text = source("Src/Lib/DownloadHelper.cpp")
        text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
        worker = function_body(text, "static DWORD WINAPI ThreadDownloadFile", "DWORD DownloadNewVersion(")
        self.assertIn("params.valid=VerifyDigitalCertificate(fname,params.signer)", worker)
        self.assertNotIn("if (params.signer)", worker)
        self.assertNotIn("lStatus!=CERT_E_EXPIRED", text)
        self.assertIn("HTTP_QUERY_STATUS_CODE", text)

    def test_independent_msi_outputs(self):
        text = source("tools/Build.ps1")
        self.assertIn("'x86'='Setup32.msi'", text)
        self.assertIn("'x64'='Setup64.msi'", text)
        self.assertIn("Verify-Msi.ps1", text)
        self.assertIn("$buildFull = $Full -or -not $MsiOnly", text)
        self.assertNotRegex(text, r"(?i)setup\.exe.*extract")
        installer = source("Src/Setup/Setup.wxs")
        self.assertIn('EmbedCab="yes"', installer)
        self.assertNotIn("VersionNT&gt;=1000", installer)


@unittest.skipUnless(sys.platform == "win32", "Win32 regression")
class NativeRegressions(unittest.TestCase):
    def test_ansi_spanish_conversion(self):
        kernel = C.WinDLL("kernel32", use_last_error=True)
        convert = kernel.MultiByteToWideChar
        convert.argtypes = [C.c_uint, C.c_uint, C.c_char_p, C.c_int, C.c_wchar_p, C.c_int]
        convert.restype = C.c_int
        data = b"Name=M\xfasica\r\n"
        size = convert(1252, 0, data, len(data), None, 0)
        output = C.create_unicode_buffer(size + 1)
        self.assertEqual(convert(1252, 0, data, len(data), output, size), size)
        self.assertEqual(output.value, "Name=Música\r\n")
        parser = source("Src/Lib/SettingsParser.cpp")
        acp = parser[parser.index("// ACP"):parser.index("void CSettingsParser::LoadText( const wchar_t")]
        self.assertEqual(acp.count("MultiByteToWideChar(CP_ACP"), 2)
        self.assertNotIn("MultiByteToWideChar(CP_UTF8", acp)

    def test_virtual_folder_does_not_become_a_filesystem_path(self):
        shell, ole = C.WinDLL("shell32"), C.WinDLL("ole32")
        ole.CoInitialize.argtypes = [C.c_void_p]
        ole.CoInitialize.restype = C.c_long
        ole.CoTaskMemFree.argtypes = [C.c_void_p]
        shell.SHGetSpecialFolderLocation.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_void_p)]
        shell.SHGetSpecialFolderLocation.restype = C.c_long
        shell.SHGetPathFromIDListW.argtypes = [C.c_void_p, C.c_wchar_p]
        shell.SHGetPathFromIDListW.restype = C.c_int
        initialized = ole.CoInitialize(None)
        pidl = C.c_void_p()
        try:
            self.assertGreaterEqual(shell.SHGetSpecialFolderLocation(None, 0x11, C.byref(pidl)), 0)
            self.assertFalse(shell.SHGetPathFromIDListW(pidl, C.create_unicode_buffer(260)))
        finally:
            if pidl.value:
                ole.CoTaskMemFree(pidl)
            if initialized >= 0:
                ole.CoUninitialize()


if __name__ == "__main__":
    unittest.main(verbosity=2)
