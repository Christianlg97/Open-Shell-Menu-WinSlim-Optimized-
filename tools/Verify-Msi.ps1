param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][ValidateSet('x86','x64','ARM64')][string]$Architecture,
    [Parameter(Mandatory=$true)][string]$Version
)
$ErrorActionPreference='Stop'
$installer=$null; $database=$null; $summary=$null; $view=$null
function Read-MsiStrings([object]$Database,[string]$Query) {
    $queryView=$null; $queryRecord=$null
    try {
        $queryView=$Database.OpenView($Query)
        $queryView.Execute()
        while ($queryRecord=$queryView.Fetch()) {
            [string]$queryRecord.StringData(1)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($queryRecord)
            $queryRecord=$null
        }
    } finally {
        if ($null -ne $queryRecord) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($queryRecord) }
        if ($null -ne $queryView) {
            $queryView.Close()
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($queryView)
        }
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
    Write-Host "Verified standalone $Architecture MSI: $MsiPath"
} finally {
    foreach ($item in @($view,$summary,$database,$installer)) {
        if ($null -ne $item) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) }
    }
}
