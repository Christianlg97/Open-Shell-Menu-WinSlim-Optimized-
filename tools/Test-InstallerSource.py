"""Validate installer variants and project references without invoking build tools."""
from pathlib import Path
import base64
import os
import re
import subprocess
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
NS = {'w': 'http://schemas.microsoft.com/wix/2006/wi'}

def preprocess(text, variables):
    stack = []
    enabled = True
    output = []
    def substitute(value):
        return re.sub(r'\$\(([^)]+)\)', lambda m: variables[m[1]], value)
    def compare(expression):
        groups = re.split(r'\s+Or\s+', expression, flags=re.I)
        def term(value):
            match = re.fullmatch(r'\s*(.*?)\s*(!=|=)\s*(.*?)\s*', value)
            assert match, value
            left, operator, right = match.groups()
            equal = substitute(left).strip('"') == substitute(right).strip('"')
            return equal if operator == '=' else not equal
        return any(all(term(part) for part in re.split(r'\s+And\s+', group, flags=re.I)) for group in groups)
    for token in re.split(r'(<\?(?:if|ifdef|elseif|else|endif|define)\b.*?\?>)', text, flags=re.S):
        if not token.startswith('<?') or token.startswith('<?xml'):
            if enabled:
                output.append(substitute(token))
            continue
        command, _, value = token[2:-2].strip().partition(' ')
        if command in ('if', 'ifdef'):
            selected = enabled and (value in variables if command == 'ifdef' else compare(value))
            stack.append([enabled, selected])
            enabled = selected
        elif command == 'elseif':
            parent, selected = stack[-1]
            enabled = parent and not selected and compare(value)
            stack[-1][1] |= enabled
        elif command == 'else':
            parent, selected = stack[-1]
            enabled = parent and not selected
            stack[-1][1] = True
        elif command == 'endif':
            enabled = stack.pop()[0]
        elif command == 'define' and enabled:
            name, definition = value.split('=', 1)
            variables['var.' + name.strip()] = definition.strip().strip('"')
    assert not stack
    return ''.join(output)

def main():
    output = ROOT / 'build/static-checks'
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / 'Src/Setup/Setup.wxs').read_text(encoding='utf-8-sig')
    for arch in ('x86', 'x64', 'ARM64'):
        for rust in (False, True):
            for language in ('en-US', 'es-ES'):
                variables = {'var.x64': str(int(arch == 'x64')), 'var.ARM64': str(int(arch == 'ARM64')),
                             'var.CS_LANG_NAME': language, 'var.CS_LANG_FOLDER': 'English' if language == 'en-US' else 'Spanish',
                             'env.CS_VERSION': '4.4.1004', 'env.CS_VERSION_NUM': str((4<<24)|(4<<16)|1004)}
                if rust:
                    variables['env.CS_WINSLIM_RUST'] = '1'
                text = preprocess(source, variables)
                product = ET.fromstring(text).find('w:Product', NS)
                features = {feature.get('Id'): feature for feature in product.iter('{' + NS['w'] + '}Feature')}
                expected = {'OpenShell', 'StartMenu'}
                assert set(features) == expected, (arch, features.keys())
                assert features['StartMenu'].get('Absent') == 'disallow'
                components = {item.get('Id') for item in product.iter('{' + NS['w'] + '}Component')}
                for item in product.iter('{' + NS['w'] + '}ComponentRef'):
                    assert item.get('Id') in components, item.get('Id')
                file_ids = [item.get('Id') for item in product.iter('{' + NS['w'] + '}File')]
                assert len(file_ids) == len(set(file_ids)), (arch, file_ids)
                for item in product.iter('{' + NS['w'] + '}RegistrySearch'):
                    assert item.get('Type') in ('raw', 'file', 'directory')
                assert not any(name.startswith('WinSlimDarkMode') for name in file_ids)
                assert {'WinSlimProfile.xml', 'WinSlimStartButton.bmp', 'FluentMetro.skin', 'FluentMetro.skin7'} <= set(file_ids)
                for item in product.iter('{' + NS['w'] + '}File'):
                    name=item.get('Source', '')
                    if name.startswith('WinSlim\\'):
                        assert (ROOT / 'Src/Setup' / name).is_file(), name
                (output / f'{arch}-{int(rust)}-{language}.xml').write_text(text, encoding='utf-8')
    print('12 installer source variants: features, component references, architecture payloads OK.')
    solution = (ROOT / 'Src/OpenShell.sln').read_text(encoding='utf-8-sig')
    for name in re.findall(r'^Project\([^\n]+ = "[^\n]+", "([^"\n]+\.vcxproj)"', solution, flags=re.M):
        path = ROOT / 'Src' / name
        assert path.is_file(), path
    ns = {'m': 'http://schemas.microsoft.com/developer/msbuild/2003'}
    for project in (ROOT / 'Src').rglob('*.vcxproj'):
        tree = ET.parse(project)
        for tag in ('ProjectReference', 'ClCompile', 'ResourceCompile'):
            for item in tree.findall('.//m:' + tag, ns):
                name = item.get('Include')
                if name and '$' not in name and '*' not in name:
                    assert (project.parent / name).is_file(), (project, name)
    print('Solution/project source and resource references OK.')
    xsd = Path(os.environ.get('LOCALAPPDATA', '')) / 'OpenShellBuild/Tools/wix-3.14.1/doc/wix.xsd'
    if os.name == 'nt' and xsd.is_file():
        def ps_quote(path):
            return "'" + str(path).replace("'", "''") + "'"
        code = r"""
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
$settings=New-Object System.Xml.XmlReaderSettings
$settings.ValidationType=[System.Xml.ValidationType]::Schema
[void]$settings.Schemas.Add('http://schemas.microsoft.com/wix/2006/wi',XSD)
foreach($file in [IO.Directory]::GetFiles(OUTPUT,'*.xml')) {
    $reader=[Xml.XmlReader]::Create($file,$settings)
    try { while($reader.Read()) {} } finally { $reader.Dispose() }
}
[Console]::WriteLine('WiX 3.14.1 XSD validation OK (no WiX tools executed).')
""".replace('XSD', ps_quote(xsd), 1).replace('OUTPUT', ps_quote(output), 1)
        encoded = base64.b64encode(code.encode('utf-16-le')).decode()
        subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand', encoded], check=True)
    else:
        print('WiX XSD not found: XML/graph checks completed; schema check skipped.')

if __name__ == '__main__':
    main()
