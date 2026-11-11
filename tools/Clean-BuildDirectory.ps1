param([Parameter(Mandatory=$true)][string]$RepositoryRoot, [Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
$repository = [IO.Path]::GetFullPath($RepositoryRoot)
$setup = [IO.Path]::GetFullPath((Join-Path $repository 'Src\Setup'))
$target = [IO.Path]::GetFullPath($Path).TrimEnd('\')
$allowed = @('Output', 'Temp', 'Final') | ForEach-Object { Join-Path $setup $_ }
if (-not (Test-Path -LiteralPath (Join-Path $setup 'BuildBinaries.bat')) -or $target -notin $allowed) {
    throw "Refusing to clean a path outside the named build directories: $target"
}
if (Test-Path -LiteralPath $target) {
    if ((Get-Item -LiteralPath $target).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw "Refusing to recursively clean a reparse point: $target"
    }
    Remove-Item -LiteralPath $target -Recurse -Force
}
