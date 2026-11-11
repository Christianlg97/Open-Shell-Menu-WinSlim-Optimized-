# Test only the exact CMD hosting command, with a harmless child exit code.
# This never invokes the build, UAC, installers or compilers.
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$path=Join-Path $PSScriptRoot 'Launch-Build.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$errors)
$assignment=$ast.FindAll({param($node) $node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$arguments'},$true) | Select-Object -First 1
if (-not $assignment) { throw 'CMD hosting command was not found' }
$powershell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$encoded=[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('$ProgressPreference=''SilentlyContinue''; Write-Output ''CMD hosting verified''; exit 7'))
$argumentLine=& ([scriptblock]::Create($assignment.Right.Extent.Text))
$process=Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList $argumentLine -NoNewWindow -PassThru
$null=$process.Handle
if (-not $process.WaitForExit(15000)) { throw "CMD host test did not exit (PID $($process.Id))" }
if ($process.ExitCode -ne 7) { throw "CMD did not preserve the child exit code: $($process.ExitCode)" }
Write-Output 'Real CMD hosting and exit propagation passed; no build was run.'
