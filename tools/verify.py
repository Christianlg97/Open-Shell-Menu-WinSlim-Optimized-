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

    def test_localization_export_reports_success(self):
        text = source("Src/Setup/Utility/Utility.cpp")
        export = function_body(text, "int ExtractStrings(", "static BOOL CALLBACK EnumResLangProc")
        self.assertIn("return 0;", export[export.index("CloseHandle(hCSV)"):])
        self.assertNotIn("int res=1;", export)
        self.assertIn("delete[] pBuf;", export)

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

    def test_bitmap_cache_normalizes_row_order(self):
        text = source("Src/StartMenu/StartMenuDLL/ItemManager.cpp")
        snapshot = function_body(text, "static bool SnapshotCacheBitmap(", "bool CItemManager::CompareModuleTimeStamp(")
        self.assertNotRegex(snapshot, r"\bDIBSECTION\s+\w")
        self.assertNotIn("bmBits", snapshot)
        self.assertIn("CopyImage(bitmap,IMAGE_BITMAP,width,height,LR_CREATEDIBSECTION)", snapshot)
        self.assertIn("GetDIBits(hdc,snapshot", snapshot)
        self.assertIn("DeleteObject(snapshot)", snapshot)
        self.assertRegex(text, r"CACHE_FILE_VERSION=([3-9]|[1-9][0-9]+);")

    def test_location_does_not_wait_or_transfer_context_menu(self):
        text = source("Src/StartMenu/StartMenuDLL/MenuCommands.cpp")
        self.assertNotIn("ExecuteOnSTAThread", text)
        self.assertNotIn("worker.join()", text)
        self.assertIn("QueueOpenFolder(pItemPidl1,true)", text)
        self.assertIn("link->GetIDList(&target)", text)
        request = function_body(text, "struct OpenFolderRequest", "static DWORD WINAPI OpenFolderWorker")
        self.assertNotIn("IContextMenu", request)
        self.assertIn("FreeLibraryAndExitThread(module", text)
        # Both asynchronous paths must also close the hidden Win7 top menu.
        close = r"CloseSubMenus\(CLOSE_POST,NULL\);\s*(?://[^\n]*\n\s*)*if \(g_TopWin7Menu && s_bAllPrograms\) ::PostMessage\(g_TopWin7Menu,WM_CLOSE,0,0\);"
        self.assertRegex(text, r"QueueOpenFolder\(pItemPidl1,false\);\s*" + close)
        self.assertRegex(text, r"if \(SUCCEEDED\(queued\)\)\s*\{\s*" + close)

    def test_search_closes_event_and_calls_core(self):
        text = source("Src/StartMenu/StartMenuDLL/SearchManager.cpp")
        self.assertIn("CloseHandle(m_ExitEvent)", text)
        self.assertIn("WinSlimMatchText(", text)
        self.assertIn("std::map<std::pair<std::wstring,bool>,NameGroup>", text)

    def test_search_matches_each_item_once(self):
        text = source("Src/StartMenu/StartMenuDLL/SearchManager.cpp")
        results = function_body(text, "void CSearchManager::GetSearchResults(", "bool CSearchManager::SearchItem::MatchTextInt(")
        # One pass for programs and one for settings; settings were matched twice before.
        self.assertEqual(results.count("MatchText(searchText"), 2)

    def test_search_keeps_quoted_phrases(self):
        rust = source("Src/RustCore/src/lib.rs")
        self.assertIn("struct Tokens", rust)
        self.assertIn("Tokens { rest: search }", rust)
        self.assertNotIn(".split(|c| *c == 32)", rust)
        legacy = source("Src/Lib/RustCore.h")
        self.assertIn("WinSlimNextToken(search,searchLength,at,first,last)", legacy)
        self.assertIn("(int)(last-first)", legacy)
        self.assertNotIn("(int)(at-first)", legacy)
        native = source("tools/CoreTests.cpp")
        self.assertIn('matches(L"\\"visual studio\\"",L"Visual Studio Code",false)', native)

    def test_cache_skips_bad_icons_and_buffers_io(self):
        text = source("Src/StartMenu/StartMenuDLL/ItemManager.cpp")
        self.assertNotIn("CacheBytesRemaining", text)
        self.assertIn("class CacheReader", text)
        self.assertIn("class CacheWriter", text)
        load = function_body(text, "void CItemManager::LoadCacheFile(", "DWORD CALLBACK CItemManager::SaveCacheFileThread(")
        self.assertNotIn("ReadFile(", load)
        self.assertNotIn("SetFilePointerEx(", load)
        save = function_body(text, "DWORD CItemManager::SaveCacheFileImpl(", "void CItemManager::SaveCacheFile(")
        self.assertIn("if (!captured) continue;", save)
        self.assertNotIn("if (!ok) break;", save)
        self.assertNotIn("ItemInfo info;", save)
        self.assertNotIn("WriteFile(", save)
        self.assertIn("writer.FlushIfFull()", save)
        throttle = function_body(text, "void CItemManager::SaveCacheFile(", "void CItemManager::ClearCache(")
        self.assertNotIn("m_LastCacheSave=0", throttle)
        self.assertIn("CACHE_SAVE_INTERVAL-CACHE_RETRY_INTERVAL", throttle)

    def test_automatic_update_check_is_off_by_default(self):
        update_default = re.compile(r'\{L"Update",CSetting::TYPE_BOOL,0,0,(\d)')
        for name in ("Src/Lib/DownloadHelper.cpp", "Src/Update/Update.cpp", "Src/StartMenu/StartMenuDLL/SettingsUI.cpp"):
            with self.subTest(name=name):
                self.assertEqual(update_default.findall(source(name)), ["0"])

    def test_installer_restarts_explorer_once_and_unelevated(self):
        ns = {"w": "http://schemas.microsoft.com/wix/2006/wi"}
        product = ET.parse(ROOT / "Src/Setup/Setup.wxs").getroot().find("w:Product", ns)
        actions = {ca.get("Id"): ca for ca in product.iter("{%s}CustomAction" % ns["w"])}
        self.assertEqual(actions["StopExplorer"].get("ExeCommand"), "exitExplorer")
        self.assertEqual(actions["StartExplorer"].get("ExeCommand"), "startExplorer")
        self.assertEqual(actions["StartExplorerRollback"].get("ExeCommand"), "startExplorer")
        self.assertEqual(actions["StartExplorerRollback"].get("Execute"), "rollback")
        prop = next(p for p in product.findall("w:Property", ns) if p.get("Id") == "RESTARTEXPLORER")
        self.assertEqual((prop.get("Value"), prop.get("Secure")), ("1", "yes"))
        sequence = {c.get("Action"): c for c in product.find("w:InstallExecuteSequence", ns).findall("w:Custom", ns)}
        self.assertEqual(sequence["StopExplorer"].get("Before"), "InstallValidate")
        self.assertEqual(sequence["CloseStartMenu"].get("Before"), "StopExplorer")
        self.assertEqual(sequence["StartExplorer"].get("After"), "InstallFinalize")
        self.assertEqual(sequence["StartExplorerRollback"].get("After"), "RemoveExistingProducts")
        self.assertEqual(sequence["LaunchStartMenu"].get("After"), "StartExplorer")
        for name in ("StopExplorer", "StartExplorer", "StartExplorerRollback"):
            with self.subTest(action=name):
                # The nested uninstall of the upgraded version must never stop or start Explorer.
                self.assertIn("NOT UPGRADINGPRODUCTCODE", sequence[name].text)
                self.assertIn('RESTARTEXPLORER="1"', sequence[name].text)
        helper = source("Src/Setup/SetupHelper/SetupHelper.cpp")
        self.assertIn('#include "../ExplorerShell.h"', helper)
        self.assertIn('L"exitExplorer"', helper)
        self.assertIn("ExplorerShell::RestartIfStopped()", helper)
        shell = source("Src/Setup/ExplorerShell.h")
        # A volatile key must sit directly under Software: if it created HKCU\Software\OpenShell,
        # that parent would be volatile too and Open-Shell could not store its settings.
        marker = re.search(r'STOPPED_MARKER\[\]=L"([^"]+)"', shell).group(1)
        self.assertEqual(marker.count("\\\\"), 1)
        self.assertTrue(marker.startswith("Software\\\\"))
        self.assertIn("REG_OPTION_VOLATILE", shell)
        self.assertIn("CreateProcessWithTokenW", shell)
        self.assertIn("SECURITY_MANDATORY_MEDIUM_RID", shell)
        self.assertIn("session!=current", shell)
        setup = source("Src/Setup/Setup.cpp")
        self.assertNotIn("if (code==ERROR_SUCCESS)\n", setup.replace("\r\n", "\n"))
        self.assertIn("if (code!=ERROR_SUCCESS_REBOOT_INITIATED)", setup)
        self.assertIn("ExplorerShell::Start()", setup)

    def test_incremental_build_is_opt_in(self):
        build = source("tools/Build.ps1")
        self.assertIn("[switch]$Incremental", build)
        self.assertIn("$msbuildTarget = if ($Incremental) { 'Build' } else { 'Rebuild' }", build)
        for name in ("Src/Setup/BuildBinaries.bat", "Src/Setup/BuildArchives.bat"):
            with self.subTest(name=name):
                script = source(name)
                self.assertNotIn("/t:Rebuild", script)
                self.assertIn('if /i not "%CS_MSBUILD_TARGET%"=="Build" set "CS_MSBUILD_TARGET=Rebuild"', script)
        launcher = source("tools/Launch-Build.ps1")
        self.assertIn("(Test-WinSlimElevationRequired $Parameters)", launcher)
        # Mixed elevated/normal builds: elevated MSIs get a High label that a normal build
        # cannot delete. Detect leftovers, and never leave new ones behind.
        required = function_body(launcher, "function Test-WinSlimElevationRequired", "function Invoke-WinSlimBuildScript")
        self.assertLess(required.index("Test-WinSlimProtectedOutput"), required.index("NoInstall"))
        self.assertIn("catch [UnauthorizedAccessException] { return $true }", launcher)
        self.assertIn("/setintegritylevel M", build)
        self.assertIn("finally { Reset-WinSlimMsiIntegrity }", build)

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
