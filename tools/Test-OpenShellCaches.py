"""Run only the Open-Shell VBS step in disposable folders. Never run Main()."""
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'tools/maintenance/WinSlim_Ultra_CacheCleaner.vbs'
FRAGMENT = ROOT / 'tools/maintenance/OpenShellCacheStep.vbs.inc'
NS = {'w': 'http://schemas.microsoft.com/wix/2006/wi'}


class Integration(unittest.TestCase):
    def test_install_repair_and_startup(self):
        product = ET.parse(ROOT / 'Src/Setup/Setup.wxs').find('w:Product', NS)
        components = [c for c in product.iter('{%s}Component' % NS['w']) if c.get('Id') == 'StartMenu.exe']
        self.assertEqual(len(components), 3)
        for component in components:
            generation = next(v for v in component.findall('w:RegistryValue', NS) if v.get('Name') == 'CacheGeneration')
            self.assertEqual(generation.get('Value'), '[ProductCode]|[Date]|[Time]')
            self.assertEqual(generation.get('Root'), 'HKLM')
        sequence = product.find('w:InstallExecuteSequence', NS)
        cleanup = next(c for c in sequence if c.get('Action') == 'CleanOpenShellCaches')
        self.assertIn('REINSTALL', cleanup.text)
        self.assertIn('NOT REMOVE', cleanup.text)
        self.assertIn('NOT UPGRADINGPRODUCTCODE', cleanup.text)
        startup = (ROOT / 'Src/StartMenu/StartMenuDLL/dllmain.cpp').read_text(encoding='utf-8-sig')
        self.assertLess(startup.index('OpenShellCache::MaintainCurrentUser();'), startup.index('InitSettings();'))
        helper = (ROOT / 'Src/Setup/SetupHelper/SetupHelper.cpp').read_text(encoding='utf-8-sig')
        self.assertIn('OpenShellCache::MaintainCurrentUser(true)', helper)

    def test_vbs_wiring_and_encoding(self):
        raw = SCRIPT.read_bytes()
        self.assertTrue(raw.startswith(b'\xff\xfe'))
        source = raw.decode('utf-16')
        self.assertNotIn('\n', source.replace('\r\n', ''))
        source = source.replace('\r\n', '\n')
        self.assertIn(FRAGMENT.read_text(encoding='utf-8').rstrip(), source)
        self.assertIn('If CLEAN_OPENSHELL_CACHES Then n = n + 1', source)
        self.assertIn('        CleanOpenShellCaches\n', source)
        self.assertIn('If openShellText <> "" Then AddItem', source)


@unittest.skipUnless(os.name == 'nt', 'Windows Script Host required')
class VbsStep(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.source = SCRIPT.read_bytes().decode('utf-16')
        assert cls.source.count('Call Main()') == 1
        cls.entry = r'''
Sub CacheTestMain()
    Set objFSO = CreateObject("Scripting.FileSystemObject")
    Set logStream = Nothing
    Set warnNotes = CreateObject("Scripting.Dictionary")
    progressOn = False
    localAppData = WScript.Arguments(0)
    isDryRun = (WScript.Arguments(1) = "dry")
    CleanOpenShellCaches
    WScript.Echo openShellText
    WScript.Quit 0
End Sub
'''

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='OpenShell-cache-tests-')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.local = self.base / 'LocalAppData'
        self.root = self.local / 'OpenShell'
        self.root.mkdir(parents=True)
        self.script = self.base / 'isolated.vbs'
        self.script.write_bytes((self.source.replace('Call Main()', 'Call CacheTestMain()', 1) + self.entry).encode('utf-16'))
        self.pending = self.root / 'CacheCleanup.pending'
        self.state = self.root / 'CacheMaintenance.state'

    def cache(self):
        (self.root / 'DataCache.db').write_bytes(b'fake cache')

    def run_step(self, mode='normal', script=None):
        result = subprocess.run(['cscript.exe', '//B', '//Nologo', str(script or self.script), str(self.local), mode],
                                capture_output=True, timeout=15)
        encoding = 'oem'
        output = (result.stdout + result.stderr).decode(encoding, errors='replace')
        self.assertEqual(result.returncode, 0, output)
        return output

    def test_whole_script_parses_without_running_maintenance(self):
        syntax = self.base / 'syntax-only.vbs'
        syntax.write_bytes(self.source.replace('Call Main()', 'WScript.Quit 0', 1).encode('utf-16'))
        self.run_step(script=syntax)

    def test_empty_cache_is_untouched(self):
        self.run_step()
        self.assertEqual(list(self.root.iterdir()), [])

    def test_due_schedules_without_deleting_user_data_or_cache(self):
        self.cache()
        keep = {'MenuSettings.xml': b'preferences', 'StartButton.bmp': b'button', 'StartupLog.txt': b'log'}
        for name, data in keep.items():
            (self.root / name).write_bytes(data)
        pins = self.root / 'Pinned'
        pins.mkdir()
        (pins / 'Example.lnk').write_bytes(b'shortcut')
        self.run_step()
        self.assertTrue(self.pending.is_file())
        self.assertEqual((self.root / 'DataCache.db').read_bytes(), b'fake cache')
        for name, data in keep.items():
            self.assertEqual((self.root / name).read_bytes(), data)
        self.assertEqual((pins / 'Example.lnk').read_bytes(), b'shortcut')

    def test_dry_run_does_not_even_create_a_marker(self):
        self.cache()
        before = {p.name: p.read_bytes() for p in self.root.iterdir()}
        self.run_step('dry')
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.root.iterdir()})

    def test_pending_is_not_overwritten(self):
        self.cache()
        self.pending.write_bytes(b'existing request')
        before = self.pending.stat().st_mtime_ns
        self.run_step()
        self.assertEqual(self.pending.read_bytes(), b'existing request')
        self.assertEqual(self.pending.stat().st_mtime_ns, before)

    def test_recent_maintenance_keeps_warm_caches(self):
        self.cache()
        self.state.write_text('generation', encoding='utf-16')
        self.run_step()
        self.assertFalse(self.pending.exists())

    def test_old_maintenance_schedules_again(self):
        self.cache()
        self.state.write_text('generation', encoding='utf-16')
        old = time.time() - 31 * 86400
        os.utime(self.state, (old, old))
        self.run_step()
        self.assertTrue(self.pending.is_file())

    def test_directory_instead_of_marker_is_preserved(self):
        self.cache()
        self.pending.mkdir()
        self.run_step()
        self.assertTrue(self.pending.is_dir())

    def test_ancestor_junction_is_rejected(self):
        target = self.base / 'ActualLocalAppData'
        self.local.rename(target)
        result = subprocess.run(['cmd.exe', '/d', '/c', 'mklink', '/J', str(self.local), str(target)],
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        try:
            (target / 'OpenShell/DataCache.db').write_bytes(b'cache')
            self.run_step()
            self.assertFalse((target / 'OpenShell/CacheCleanup.pending').exists())
        finally:
            self.local.rmdir()  # Remove only the tested junction, not its target.


if __name__ == '__main__':
    unittest.main(verbosity=2)
