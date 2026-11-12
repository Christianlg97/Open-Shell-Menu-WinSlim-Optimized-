param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][ValidateSet('x86','x64','ARM64')][string]$Architecture,
    [Parameter(Mandatory=$true)][string]$Version,
    [string]$ProfileDirectory = (Join-Path $PSScriptRoot '..\Src\Setup\WinSlim')
)
$ErrorActionPreference='Stop'
$installer=$null; $database=$null; $summary=$null; $view=$null
function Read-MsiStrings([object]$Database,[string]$Query) {
    $queryView=$null; $queryRecord=$null
    try {
        $queryView=$Database.OpenView($Query)
        [void]$queryView.Execute()
        while ($queryRecord=$queryView.Fetch()) {
            [string]$queryRecord.StringData(1)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($queryRecord)
            $queryRecord=$null
        }
    } finally {
        if ($null -ne $queryRecord) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($queryRecord) }
        if ($null -ne $queryView) {
            [void]$queryView.Close()
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($queryView)
        }
    }
}
function Export-MsiStream([object]$Database,[string]$Name,[string]$Destination) {
    $streamView=$null; $streamRecord=$null; $output=$null
    try {
        $streamView=$Database.OpenView(('SELECT `Data` FROM `_Streams` WHERE `Name`=''{0}''' -f $Name.Replace("'","''")))
        [void]$streamView.Execute()
        $streamRecord=$streamView.Fetch()
        if ($null -eq $streamRecord) { throw "Missing embedded cabinet: $Name" }
        $output=[IO.File]::Open($Destination,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write)
        # msiReadStreamBytes returns one byte per BSTR character. Latin-1 maps
        # all 256 values back exactly, including NUL and high-bit bytes.
        $encoding=[Text.Encoding]::GetEncoding(28591)
        do {
            $chunk=[string]$streamRecord.ReadStream(1,65536,1)
            $bytes=$encoding.GetBytes($chunk)
            $output.Write($bytes,0,$bytes.Length)
        } while ($bytes.Length)
    } finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $streamRecord) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($streamRecord) }
        if ($null -ne $streamView) {
            [void]$streamView.Close()
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($streamView)
        }
    }
}
function Test-MsiProfilePayload([object]$Database,[string]$ProfileDirectory) {
    $assets=@(
        @{Id='WinSlimProfile.xml'; Name='MenuSettings.xml'; Directory='WinSlimProfileFiles'; Folder='WinSlim'},
        @{Id='WinSlimStartButton.bmp'; Name='StartButton.bmp'; Directory='WinSlimProfileFiles'; Folder='WinSlim'},
        @{Id='FluentMetro.skin'; Name='Fluent-Metro.skin'; Directory='Skins'; Folder='Skins'},
        @{Id='FluentMetro.skin7'; Name='Fluent-Metro.skin7'; Directory='Skins'; Folder='Skins'}
    )
    $level=@(Read-MsiStrings $Database 'SELECT `Level` FROM `Feature` WHERE `Feature`=''StartMenu''')
    if ($level.Count -ne 1 -or $level[0] -ne '1') { throw 'StartMenu must be installed by default' }
    # A private extraction folder is the only write destination. Opening the
    # database read-only and using expand.exe never runs MSI custom actions.
    $tempRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    $scratch=Join-Path $tempRoot ('OpenShell-MsiProfile-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $scratch
    $cabinets=@{}
    try {
        foreach ($asset in $assets) {
            $fileId=$asset.Id
            $component=@(Read-MsiStrings $Database ('SELECT `Component_` FROM `File` WHERE `File`=''{0}''' -f $fileId))
            if ($component.Count -ne 1) { throw "Missing or duplicate profile file: $fileId" }
            $componentId=$component[0].Replace("'","''")
            $feature=@(Read-MsiStrings $Database ('SELECT `Feature_` FROM `FeatureComponents` WHERE `Component_`=''{0}''' -f $componentId))
            $condition=@(Read-MsiStrings $Database ('SELECT `Condition` FROM `Component` WHERE `Component`=''{0}''' -f $componentId))
            if ('StartMenu' -notin $feature -or ($condition -join '')) { throw "Profile asset is not unconditionally part of StartMenu: $fileId" }
            $directory=@(Read-MsiStrings $Database ('SELECT `Directory_` FROM `Component` WHERE `Component`=''{0}''' -f $componentId))
            if ($directory.Count -ne 1 -or $directory[0] -ne $asset.Directory) { throw "Wrong profile asset directory: $fileId" }
            $parent=@(Read-MsiStrings $Database ('SELECT `Directory_Parent` FROM `Directory` WHERE `Directory`=''{0}''' -f $asset.Directory))
            $folder=@(Read-MsiStrings $Database ('SELECT `DefaultDir` FROM `Directory` WHERE `Directory`=''{0}''' -f $asset.Directory))
            if ($parent.Count -ne 1 -or $parent[0] -ne 'APPLICATIONFOLDER' -or $folder.Count -ne 1 -or ($folder[0] -split '\|')[-1] -ne $asset.Folder) {
                throw "Profile directory is not relative to the installation: $fileId"
            }
            $name=@(Read-MsiStrings $Database ('SELECT `FileName` FROM `File` WHERE `File`=''{0}''' -f $fileId))
            if ($name.Count -ne 1 -or ($name[0] -split '\|')[-1] -ne $asset.Name) { throw "Wrong installed profile filename: $fileId" }
            $sequence=@(Read-MsiStrings $Database ('SELECT `Sequence` FROM `File` WHERE `File`=''{0}''' -f $fileId))
            if ($sequence.Count -ne 1 -or $sequence[0] -notmatch '^\d+$') { throw "Invalid file sequence: $fileId" }
            $media=@(Read-MsiStrings $Database ('SELECT `Cabinet` FROM `Media` WHERE `LastSequence`>={0} ORDER BY `DiskId`' -f $sequence[0]))
            if (-not $media.Count -or -not $media[0].StartsWith('#')) { throw "Profile asset needs an external cabinet: $fileId" }
            $cabinet=$media[0].Substring(1)
            if (-not $cabinets.ContainsKey($cabinet)) {
                $cabPath=Join-Path $scratch ('payload-'+$cabinets.Count+'.cab')
                Export-MsiStream $Database $cabinet $cabPath
                $cabinets[$cabinet]=$cabPath
            }
            $expanded=& "$env:SystemRoot\System32\expand.exe" $cabinets[$cabinet] "-F:$fileId" $scratch 2>&1
            if ($LASTEXITCODE -ne 0) { throw "Cannot extract ${fileId}: $expanded" }
            $payload=Join-Path $scratch $fileId
            $expected=Join-Path $ProfileDirectory $asset.Name
            if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) { throw "File table entry has no cabinet payload: $fileId" }
            if (-not (Test-Path -LiteralPath $expected -PathType Leaf)) { throw "Missing profile source: $($asset.Name)" }
            if ((Get-FileHash -LiteralPath $payload -Algorithm SHA256 -ErrorAction Stop).Hash -ne (Get-FileHash -LiteralPath $expected -Algorithm SHA256 -ErrorAction Stop).Hash) {
                throw "Packaged profile asset differs from source: $($asset.Name)"
            }
        }
        Write-Host 'Verified bundled XML, button and Fluent-Metro: SHA256, default feature and installation paths.'
    } finally {
        # Only remove this invocation's generated child of the temp directory.
        $resolved=[IO.Path]::GetFullPath($scratch)
        if (-not [string]::Equals([IO.Path]::GetDirectoryName($resolved),$tempRoot.TrimEnd('\'),[StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($resolved) -notmatch '^OpenShell-MsiProfile-[0-9a-f]{32}$') { throw 'Unsafe MSI extraction cleanup path' }
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
try {
    $installer=New-Object -ComObject WindowsInstaller.Installer
    $database=$installer.OpenDatabase([IO.Path]::GetFullPath($MsiPath),0)
    $summary=$database.SummaryInformation(0)
    $expected=@{x86='Intel'; x64='x64'; ARM64='Arm64'}[$Architecture]
    $actual=([string]$summary.Property(7)).Split(';')[0]
    if ($actual -ine $expected) { throw "MSI architecture mismatch: expected $expected, got $actual" }
    $view=$database.OpenView('SELECT `Value` FROM `Property` WHERE `Property`=''ProductVersion''')
    $view.Execute(); $record=$view.Fetch()
    if (-not $record -or $record.StringData(1) -ne $Version.Split('-')[0]) { throw 'MSI product version mismatch' }
    [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)
    $view.Close(); [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($view); $view=$null
    $view=$database.OpenView('SELECT `Cabinet` FROM `Media`')
    $view.Execute()
    while ($record=$view.Fetch()) {
        $cabinet=[string]$record.StringData(1)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($record)
        if ($cabinet -and -not $cabinet.StartsWith('#')) { throw "MSI requires an external cabinet: $cabinet" }
    }
    $view.Close()
    $features=@(Read-MsiStrings $database 'SELECT `Feature` FROM `Feature`')
    $expectedFeatures=@('OpenShell','StartMenu')
    if (@(Compare-Object ($features | Sort-Object) ($expectedFeatures | Sort-Object)).Count) { throw "Unexpected MSI features: $($features -join ', ')" }
    $files=@(Read-MsiStrings $database 'SELECT `FileName` FROM `File`') | ForEach-Object { ($_ -split '\|')[-1] }
    if (@($files | Where-Object { $_ -match '^(ClassicExplorer|ClassicIE|DesktopToasts|Update\.exe|WinSlimDarkMode)' }).Count) { throw 'Removed module found in MSI payload' }
    foreach ($file in @('MenuSettings.xml','StartButton.bmp','Fluent-Metro.skin','Fluent-Metro.skin7')) {
        if ($file -notin $files) { throw "Missing WinSlim profile asset: $file" }
    }
    Test-MsiProfilePayload $database $ProfileDirectory
    Write-Host "Verified standalone $Architecture MSI: $MsiPath"
} finally {
    foreach ($item in @($view,$summary,$database,$installer)) {
        if ($null -ne $item) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) }
    }
}
