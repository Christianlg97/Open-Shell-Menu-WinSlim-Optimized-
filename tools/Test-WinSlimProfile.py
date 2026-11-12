"""Profile/asset checks, plus native resource/XML reads. Does not build or install."""
from pathlib import Path
import base64
import ctypes as C
import hashlib
import json
import os
import re
import struct
import subprocess
import unittest
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]
ASSETS=ROOT/'Src/Setup/WinSlim'

def settings(element):
    return {node.tag:(node.get('value'),[line.text or '' for line in node.findall('Line')]) for node in element}

class ProfileTests(unittest.TestCase):
    def test_profile_types_and_radio_values(self):
        profile=ET.parse(ASSETS/'MenuSettings.xml').getroot()
        self.assertEqual(profile.get('component'),'StartMenu')
        text=(ROOT/'Src/StartMenu/StartMenuDLL/SettingsUI.cpp').read_text(encoding='utf-8-sig')
        text=text[text.index('CSetting g_Settings[]='):text.index('void UpgradeSettings(')]
        text=re.sub(r'/\*.*?\*/','',text,flags=re.S)
        rows=re.findall(r'^\s*\{L"([^"]+)",CSetting::(TYPE_\w+)([,}][^\n]*)',text,flags=re.M)
        self.assertEqual(len(profile),len({node.tag for node in profile}))
        for node in profile:
            matches=[i for i,row in enumerate(rows) if row[0]==node.tag and row[1] not in ('TYPE_GROUP','TYPE_RADIO')]
            self.assertEqual(len(matches),1,node.tag)
            index=matches[0]
            kind=rows[index][1]
            if kind=='TYPE_MULTISTRING':
                self.assertIsNone(node.get('value'),node.tag)
                self.assertTrue(all(child.tag=='Line' for child in node),node.tag)
            elif kind=='TYPE_BOOL':
                self.assertIn(node.get('value'),('0','1'),node.tag)
            elif kind=='TYPE_INT' and rows[index+1][1]=='TYPE_RADIO':
                choices=[]
                for row in rows[index+1:]:
                    if row[1]!='TYPE_RADIO': break
                    choices.append(row[0])
                self.assertIn(node.get('value'),choices,node.tag)
            elif kind in ('TYPE_INT','TYPE_COLOR','TYPE_HOTKEY','TYPE_HOTKEY_ANY'):
                self.assertLessEqual(-2147483648,int(node.get('value')))
                self.assertLessEqual(int(node.get('value')),4294967295)
            else:
                self.assertIsNotNone(node.get('value'),node.tag)

    def test_existing_design_animations_and_utilities_are_preserved(self):
        reference=ROOT.parent/'WinSlim Profile/Menu Settings.xml'
        if not reference.is_file(): self.skipTest('External source profile not present in this checkout')
        original=settings(ET.parse(reference).getroot())
        installed=settings(ET.parse(ASSETS/'MenuSettings.xml').getroot())
        # Reviewed profile is already tuned. No extra functional/visual options
        # are disabled merely to manufacture a performance difference.
        self.assertEqual(installed,original)
        for name in ('PreCacheIcons','DelayIcons','MainMenuAnimation','SubMenuAnimation','SkinOptionsW7','MenuItems7'):
            self.assertEqual(installed[name],original[name])

    def test_assets_are_unchanged(self):
        manifest=json.loads((ASSETS/'Assets.json').read_text())
        for name,digest in manifest['files'].items():
            self.assertEqual(hashlib.sha256((ASSETS/name).read_bytes()).hexdigest(),digest,name)
        button=(ASSETS/'StartButton.bmp').read_bytes()
        self.assertEqual(button[:2],b'BM')
        width,height=struct.unpack_from('<ii',button,18)
        self.assertEqual((width,height),(48,144))
        self.assertEqual(struct.unpack_from('<H',button,28)[0],24)

    @unittest.skipUnless(os.name=='nt','Native Windows resource check')
    def test_fluent_skins_contain_loadable_resources(self):
        kernel=C.WinDLL('kernel32',use_last_error=True)
        kernel.LoadLibraryExW.argtypes=[C.c_wchar_p,C.c_void_p,C.c_uint]
        kernel.LoadLibraryExW.restype=C.c_void_p
        kernel.FindResourceW.argtypes=[C.c_void_p,C.c_void_p,C.c_wchar_p]
        kernel.FindResourceW.restype=C.c_void_p
        kernel.SizeofResource.argtypes=[C.c_void_p,C.c_void_p]
        kernel.SizeofResource.restype=C.c_uint
        kernel.FreeLibrary.argtypes=[C.c_void_p]
        kernel.FreeLibrary.restype=C.c_int
        for name in ('Fluent-Metro.skin','Fluent-Metro.skin7'):
            # AS_DATAFILE | AS_IMAGE_RESOURCE: no skin executable code is run.
            module=kernel.LoadLibraryExW(str(ASSETS/name),None,0x22)
            self.assertTrue(module,name)
            try:
                resource=kernel.FindResourceW(module,1,'SKIN')
                self.assertTrue(resource,name)
                self.assertGreater(kernel.SizeofResource(module,resource),0,name)
            finally:
                kernel.FreeLibrary(module)

    @unittest.skipUnless(os.name=='nt','MSXML is only available on Windows')
    def test_msxml_preserves_unicode_labels_and_menu_lines(self):
        path=str(ASSETS/'MenuSettings.xml').replace("'","''")
        script=r"""
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$doc=New-Object -ComObject Msxml2.FreeThreadedDOMDocument
try {
    $doc.async=$false
    $doc.resolveExternals=$false
    $doc.validateOnParse=$false
    if(-not $doc.load('PROFILE')) { throw $doc.parseError.reason }
    $lines=@($doc.selectNodes('/Settings/MenuItems7/Line') | ForEach-Object { $_.text })
    $text=[String]::Join("`n",$lines)+"`n"
    [Console]::WriteLine([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($text)))
} finally { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($doc) }
""".replace('PROFILE',path)
        encoded=base64.b64encode(script.encode('utf-16-le')).decode()
        result=subprocess.run(['powershell.exe','-NoLogo','-NoProfile','-NonInteractive','-OutputFormat','Text','-EncodedCommand',encoded],check=True,text=True,capture_output=True)
        actual=base64.b64decode(result.stdout.strip()).decode('utf-16-le')
        expected=''.join((line.text or '')+'\n' for line in ET.parse(ASSETS/'MenuSettings.xml').getroot().find('MenuItems7'))
        self.assertEqual(actual,expected)

if __name__=='__main__':
    unittest.main(verbosity=2)
