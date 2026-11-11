param(
    [Parameter(Mandatory=$true)][string]$MsiPath,
    [Parameter(Mandatory=$true)][ValidateSet('x86','x64','ARM64')][string]$Architecture,
    [Parameter(Mandatory=$true)][string]$Version
)
$ErrorActionPreference='Stop'
$installer=$null; $database=$null; $summary=$null; $view=$null
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
    Write-Host "Verified standalone $Architecture MSI: $MsiPath"
} finally {
    foreach ($item in @($view,$summary,$database,$installer)) {
        if ($null -ne $item) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($item) }
    }
}
