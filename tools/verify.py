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
        self.assertIn("OpenShellSearch::PreparePrograms", text)
        self.assertIn("std::map<std::pair<std::wstring,bool>,NameGroup>", source("Src/Lib/SearchCatalog.h"))

    def test_search_ui_only_reads_published_catalogs(self):
        text = source("Src/StartMenu/StartMenuDLL/SearchManager.cpp")
        results = function_body(text, "void CSearchManager::GetSearchResults(", "bool CSearchManager::SearchItem::MatchTextInt(")
        self.assertNotIn("UpdateItemInfo", results)
        self.assertNotIn("std::sort(programs", results)
        self.assertNotIn("m_ProgramItems", results)
        self.assertNotIn("m_SettingsItems", results)
        self.assertIn("programs=m_ProgramCatalog", results)
        self.assertIn("settings=m_SettingsCatalog", results)
        publish = function_body(text, "bool CSearchManager::PublishSearchCatalog(", "void CSearchManager::LoadItemRanks(")
        self.assertEqual(publish.count("if (request.requestId<m_LastProgramsRequestId) return false;"), 2)
        self.assertIn("catalog->swap(programs?m_ProgramItems:m_SettingsItems)", publish)
        self.assertIn("m_ProgramCatalog.swap(replacement)", publish)
        self.assertIn("m_SettingsCatalog.swap(replacement)", publish)
        self.assertNotIn("m_ProgramItemsOld", text)
        self.assertNotIn("m_SettingsItemsOld", text)
        header = source("Src/StartMenu/StartMenuDLL/SearchManager.h")
        self.assertIn("std::shared_ptr<const std::vector<SearchItem>>", header)

    def test_search_threads_are_created_only_on_demand(self):
        text = source("Src/StartMenu/StartMenuDLL/SearchManager.cpp")
        init = function_body(text, "void CSearchManager::Init(", "bool CSearchManager::EnsureSearchWorker(")
        self.assertNotIn("CreateThread", init)
        ensure = function_body(text, "bool CSearchManager::EnsureSearchWorker(", "void CSearchManager::Close(")
        self.assertIn("busy>=m_SearchThreadSlots", ensure)
        self.assertIn("m_SearchThreadSlots<_countof(m_SearchThreads)", ensure)
        self.assertIn("if (thread) m_SearchThreads[m_SearchThreadSlots++]=thread;", ensure)
        begin = function_body(text, "void CSearchManager::BeginSearch(", "void CSearchManager::CloseMenu(")
        self.assertLess(begin.index("EnsureSearchWorker()"), begin.index("SetEvent(m_SearchEvent)"))
        self.assertIn("m_LastCompletedId=m_LastRequestId", begin)
        empty = begin[begin.index("if (searchText.IsEmpty())"):begin.index("m_SearchRequest.bSearchPrograms=")]
        self.assertIn("m_SearchRequest.requestId=0", empty)
        self.assertIn("m_IndexedItems.clear()", empty)
        self.assertIn("return;", empty)

    def test_search_ranking_shell_calls_do_not_hold_data_or_rank_lock(self):
        text = source("Src/StartMenu/StartMenuDLL/SearchManager.cpp")
        add = function_body(text, "bool CSearchManager::AddSearchItem(", "void CSearchManager::CollectSearchItems(")
        shell = add.index("pItem->GetDisplayName(SIGDN_PARENTRELATIVEPARSING")
        self.assertLess(shell, add.index("LOCK_RANKS"))
        self.assertLess(shell, add.index("LOCK_DATA"))
        self.assertIn("m_SettingNames.emplace", add)

    def test_search_appid_resolver_belongs_to_the_calling_apartment(self):
        text = source("Src/StartMenu/StartMenuDLL/ItemManager.cpp")
        factory = function_body(text, "static void CreateAppResolver(", "static bool DetectGrayscaleImage(")
        self.assertNotIn("g_pAppResolver", factory)
        self.assertIn("CComPtr<IApplicationResolver> &resolver", factory)
        begin = text.index("if (newInfo.bLink && newInfo.appid.IsEmpty() && (refreshFlags&INFO_LINK_APPID))")
        end = text.index("if (!newInfo.bIconOnly)", begin)
        resolver = text[begin:end]
        self.assertRegex(resolver, r"if \(GetCurrentThreadId\(\)==m_MainThreadId\)\s*\{\s*if \(!g_pAppResolver\) CreateAppResolver\(g_pAppResolver\);\s*resolver=g_pAppResolver;")
        self.assertIn("CreateAppResolver(resolver)", resolver)
        self.assertIn("resolver->GetAppIDForShortcut", resolver)
        self.assertNotIn("g_pAppResolver->GetAppIDForShortcut", resolver)

    def test_folder_changes_batch_and_cancel(self):
        text = source("Src/StartMenu/StartMenuDLL/ItemManager.cpp")
        preload = function_body(text, "void CItemManager::PreloadItemsThread(", "DWORD CALLBACK CItemManager::StaticPreloadItemsThread(")
        self.assertNotIn("Sleep(", preload)
        self.assertIn("OpenShellFolders::WaitForChanges", preload)
        batch = source("Src/Lib/DirectoryChangeBatch.h")
        self.assertIn("waits[0]=stop", batch)
        self.assertIn("WaitForSingleObject(stop,delay)", batch)
        self.assertIn("changed|=masks[i]", batch)
        self.assertIn("FindNextChangeNotification", batch)
        self.assertNotIn("ResetEvent", batch)

    def test_button_tracks_leave_without_continuous_polling(self):
        text = source("Src/StartMenu/StartMenuDLL/StartButton.cpp")
        self.assertIn("MESSAGE_HANDLER( WM_MOUSELEAVE, OnMouseLeave )", text)
        move = function_body(text, "LRESULT CStartButton::OnMouseMove(", "LRESULT CStartButton::OnMouseLeave(")
        self.assertIn("if (!m_bTrackMouse)", move)
        self.assertIn("TrackMouseEvent(&track)", move)
        self.assertRegex(move, r"if \(m_bTrackMouse\)\s*KillTimer\(TIMER_LEAVE\);")
        leave = function_body(text, "LRESULT CStartButton::OnMouseLeave(", "void CStartButton::TaskBarMouseMove(")
        self.assertIn("m_bTrackMouse=false", leave)
        self.assertIn("PointAroundStartButton(m_TaskbarId)", leave)
        self.assertIn("SetTimer(TIMER_LEAVE,30)", leave)

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

    def test_detached_threads_close_their_handles(self):
        # A discarded CreateThread handle keeps a thread object alive in Explorer.
        for path in (ROOT / "Src/StartMenu").rglob("*.cpp"):
            for number, line in enumerate(path.read_text(encoding="utf-8-sig", errors="replace").splitlines(), 1):
                with self.subTest(path=path.name, line=number):
                    self.assertNotRegex(line, r"^\s*CreateThread\(")

    def test_start_screen_thumbnail_request_outlives_timeout(self):
        text = source("Src/StartMenu/StartMenuDLL/StartMenuDLL.cpp")
        icon = function_body(text, "HBITMAP GetStartScreenIcon(", "STARTMENUAPI LRESULT CALLBACK HookInject(")
        self.assertNotIn("(LPARAM)&info", icon)
        self.assertIn("pRequest->refCount=2;", icon)
        self.assertIn("ReleaseStartScreenThumbInfo(pRequest);", icon)
        self.assertIn("if (!bitmap || !bits)", icon)
        hook = function_body(text, "static LRESULT CALLBACK HookAppManager(", "static LRESULT CALLBACK HookNewWindow(")
        self.assertIn("ReleaseStartScreenThumbInfo(pInfo);", hook)

    def test_taskbar_edge_is_cached_for_mouse_hooks(self):
        text = source("Src/StartMenu/StartMenuDLL/StartMenuDLL.cpp")
        hit = function_body(text, "bool PointAroundStartButton(", "// declare few interfaces")
        self.assertEqual(hit.count("GetTaskbarPosition("), 1)
        self.assertIn("!EqualRect(&taskBar->edgeRect,&rc)", hit)
        self.assertIn("edge=0xFFFFFFFF", source("Src/StartMenu/StartMenuDLL/StartMenuDLL.h"))

    def test_settings_getters_use_the_index(self):
        text = source("Src/Lib/Settings.cpp")
        init = function_body(text, "void CSettingsManager::Init(", "CSettingsManager::~CSettingsManager(")
        self.assertLess(init.index("BuildLookup();"), init.index("LoadSettings(false);"))
        getters = function_body(text, "bool CSettingsManager::GetSettingBool( const wchar_t *name ) const", "static bool OpenSettingsKeys(")
        self.assertNotIn("for (", getters)
        self.assertEqual(getters.count("LookupSetting(LOOKUP_"), 5)
        # The index must reproduce the linear scan: unique ASCII names per getter type.
        table = source("Src/StartMenu/StartMenuDLL/SettingsUI.cpp")
        table = table[table.index("CSetting g_Settings[]"):]
        classes = {"TYPE_BOOL": 0, "TYPE_INT": 1, "TYPE_HOTKEY": 1, "TYPE_HOTKEY_ANY": 1, "TYPE_COLOR": 1}
        keys = [(name.lower(), classes.get(kind, 2)) for name, kind in re.findall(r'\{L"([^"]+)",CSetting::(TYPE_\w+)', table[:table.index("{NULL}")])
                if kind not in ("TYPE_GROUP", "TYPE_RADIO")]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(all(name.isascii() for name, _ in keys))

    def test_one_level_folders_do_not_watch_their_subtree(self):
        text = source("Src/StartMenu/StartMenuDLL/ItemManager.cpp")
        preload = function_body(text, "void CItemManager::PreloadItemsThread(", "DWORD CALLBACK CItemManager::StaticPreloadItemsThread(")
        self.assertNotIn("FindFirstChangeNotification(path,TRUE,", preload)
        self.assertIn("g_CacheFolders[i].levels>1 || g_CacheFolders[i].folder==FOLDERID_MetroApps", preload)

    def test_fader_list_is_locked(self):
        text = source("Src/StartMenu/StartMenuDLL/MenuCommands.cpp")
        fader = text[text.index("CMenuFader::CMenuFader("):text.index("LRESULT CMenuFader::OnEraseBkgnd(")]
        self.assertEqual(fader.count("AcquireSRWLockExclusive(&g_FaderLock);"), 2)
        clear = function_body(text, "void CMenuFader::ClearAll(", "\n}\n")
        self.assertIn("AcquireSRWLockShared(&g_FaderLock);", clear)
        self.assertNotIn("s_Faders[0]->SendMessage", clear)
        thread = function_body(text, "static DWORD WINAPI FaderThreadProc(", "void CMenuContainer::FadeOutItem(")
        self.assertIn("if (!pFader->m_hWnd)", thread)

    def test_removed_modules_are_not_built_or_installed(self):
        for folder in ("ClassicExplorer", "ClassicIE", "Update", "WinSlimDarkMode"):
            self.assertFalse(list((ROOT / "Src" / folder).rglob("*.cpp")))
            self.assertNotIn('= "' + folder + '"', source("Src/OpenShell.sln"))
        self.assertFalse((ROOT / "Src/Lib/DownloadHelper.cpp").exists())
        for name in ("Src/Setup/Setup.wxs", "Src/Setup/BuildBinaries.bat", "Src/Setup/BuildArchives.bat"):
            with self.subTest(name=name):
                self.assertNotRegex(source(name), r"ClassicExplorer|ClassicIE|DesktopToasts|Update\.exe|WinSlimDarkMode")
        self.assertNotIn("CheckForNewVersion", source("Src/StartMenu/StartMenuDLL/MenuContainer.cpp"))
        self.assertNotRegex(source("Src/StartMenu/StartMenuDLL/SettingsUI.cpp"), r'\{L"Update",')

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
        self.assertEqual(sequence["StopExplorer"].get("Before"), "CleanOpenShellCaches")
        self.assertEqual(sequence["CleanOpenShellCaches"].get("Before"), "InstallValidate")
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

    def test_installed_profile_is_an_editable_default(self):
        settings=source("Src/Lib/Settings.cpp")
        init=function_body(settings, "void CSettingsManager::Init(", "CSettingsManager::~CSettingsManager(")
        self.assertLess(init.index("ReadSettingsXml(profile,true)"),init.index("LoadSettings(false)"))
        reader=function_body(settings,"CString CSettingsManager::ReadSettingsXml(","static void SaveSettingValue(")
        self.assertIn("if (!bDefaults) ResetSettings();",reader)
        self.assertIn("pSetting->defValue=pSetting->value;",reader)
        self.assertIn("if (bDefaults) return CString();",reader)
        self.assertNotIn("SaveSettings(",reader)
        self.assertNotIn("SetDWORDValue(",reader)
        self.assertIn("FLAG_PROFILE_DEFAULT",source("Src/Lib/Settings.h"))

    def test_saved_console_items_are_migrated_once_before_settings_load(self):
        init = function_body(source("Src/StartMenu/StartMenuDLL/dllmain.cpp"), "static DWORD CALLBACK DllInitThread(", "STARTMENUAPI void WaitDllInitThread(")
        self.assertLess(init.index("OpenShellCache::MaintainCurrentUser();"), init.index("OpenShellMigration::MigrateCurrentUser();"))
        self.assertLess(init.index("OpenShellMigration::MigrateCurrentUser();"), init.index("InitSettings();"))
        migration = source("Src/Lib/SettingsMigration.h")
        self.assertIn('L"MenuItems7"', migration)
        self.assertIn("level>=CurrentLevel", migration)
        for forbidden in ("RegDeleteValue", "RegDeleteKey", "RegDeleteTree", "DeleteFile", "RegCreateKey"):
            self.assertNotIn(forbidden, migration)
        self.assertIn('<ClInclude Include="SettingsMigration.h" />', source("Src/Lib/Lib.vcxproj"))
        self.assertIn("CheckSettingsMigration();", source("tools/CoreTests.cpp"))
        # The shipped profile already has the flag the migration adds to saved copies.
        items = ET.parse(ROOT / "Src/Setup/WinSlim/MenuSettings.xml").getroot().find("MenuItems7")
        lines = [line.text for line in items.iter("Line")]
        consoles = [line.split(".")[0] for line in lines if re.search(r"(?i)\.Link=.*\\(cmd|powershell)\.exe$", line)]
        self.assertEqual(len(consoles), 2)
        for name in consoles:
            self.assertIn(f"{name}.Settings=OPEN_UP_CHILDREN|RUN_AS_ADMIN", lines)

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
    def test_localization_version_resource_can_be_queried_and_copied(self):
        kernel = C.WinDLL('kernel32', use_last_error=True)
        version = C.WinDLL('version', use_last_error=True)
        kernel.GetModuleHandleW.argtypes = [C.c_wchar_p]
        kernel.GetModuleHandleW.restype = C.c_void_p
        kernel.FindResourceW.argtypes = [C.c_void_p, C.c_void_p, C.c_void_p]
        kernel.FindResourceW.restype = C.c_void_p
        kernel.LoadResource.argtypes = [C.c_void_p, C.c_void_p]
        kernel.LoadResource.restype = C.c_void_p
        kernel.SizeofResource.argtypes = [C.c_void_p, C.c_void_p]
        kernel.SizeofResource.restype = C.c_uint32
        kernel.LockResource.argtypes = [C.c_void_p]
        kernel.LockResource.restype = C.c_void_p
        version.VerQueryValueW.argtypes = [C.c_void_p, C.c_wchar_p, C.POINTER(C.c_void_p), C.POINTER(C.c_uint)]
        version.VerQueryValueW.restype = C.c_int
        module = kernel.GetModuleHandleW('kernel32.dll')
        resource = kernel.FindResourceW(module, 1, 16)
        self.assertTrue(resource)
        data = kernel.LockResource(kernel.LoadResource(module, resource))
        size = kernel.SizeofResource(module, resource)
        copied = C.create_string_buffer(C.string_at(data, size))
        values = []
        for block in (data, C.cast(copied, C.c_void_p)):
            pointer, length = C.c_void_p(), C.c_uint()
            self.assertTrue(version.VerQueryValueW(block, '\\', C.byref(pointer), C.byref(length)))
            self.assertGreaterEqual(length.value, 52)
            values.append(C.string_at(pointer, 52))
        self.assertEqual(values[0], values[1])

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
