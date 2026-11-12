param(
    [ValidateRange(1,3600)][int]$DurationSeconds = 30,
    [ValidateRange(100,60000)][int]$IntervalMilliseconds = 1000,
    [string]$Scenario = 'observed-session',
    [string]$OutputPath = (Join-Path $PSScriptRoot ('..\build\static-checks\performance-'+[guid]::NewGuid().ToString('N')+'.json'))
)
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
# Read-only sampling: no registry changes, cache purge, menu automation or
# process restart. Explorer totals include Windows and all loaded extensions.
$current=[Diagnostics.Process]::GetCurrentProcess()
$session=$current.SessionId
$current.Dispose()
$logicalProcessors=[Environment]::ProcessorCount
$samples=[Collections.Generic.List[object]]::new()
$processInfo=@{}
$clock=[Diagnostics.Stopwatch]::StartNew()
$started=[DateTime]::UtcNow.ToString('o')
while ($true) {
    $processes=@(Get-Process -Name explorer,StartMenu -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        try {
            if ($process.SessionId -ne $session) { continue }
            # Include creation time so a reused PID never joins two processes.
            $startTicks=$process.StartTime.ToUniversalTime().Ticks
            $key="$($process.Id):$startTicks"
            $cpu=$process.TotalProcessorTime.TotalSeconds
            $elapsed=$clock.Elapsed.TotalSeconds
            $samples.Add([pscustomobject]@{
                Key=$key; Name=$process.ProcessName; Id=$process.Id
                ElapsedSeconds=$elapsed; CpuSeconds=$cpu
                WorkingSetBytes=$process.WorkingSet64
                PrivateBytes=$process.PrivateMemorySize64
                Handles=$process.HandleCount; Threads=$process.Threads.Count
            })
            if (-not $processInfo.ContainsKey($key)) {
                $module=$null; $moduleError=$null
                try { $module=$process.Modules | Where-Object ModuleName -eq 'StartMenuDLL.dll' | Select-Object -First 1 }
                catch { $moduleError=$_.Exception.Message }
                $processInfo[$key]=[pscustomobject]@{
                    Key=$key; Name=$process.ProcessName; Id=$process.Id
                    OpenShellDll=$(if ($null -ne $module) { $module.FileName } else { $null })
                    OpenShellVersion=$(if ($null -ne $module) { $module.FileVersionInfo.FileVersion } else { $null })
                    ModuleReadError=$moduleError
                }
            }
        } catch {
            # A process may exit between enumeration and a property read.
            Write-Warning "Cannot sample process $($process.Id): $($_.Exception.Message)"
        } finally { $process.Dispose() }
    }
    $remaining=$DurationSeconds-$clock.Elapsed.TotalSeconds
    if ($remaining -le 0) { break }
    Start-Sleep -Milliseconds ([int][Math]::Min($IntervalMilliseconds,[Math]::Max(1,$remaining*1000)))
}
$clock.Stop()
if (-not $samples.Count) { throw 'No Explorer or StartMenu process could be sampled in this session.' }
$summary=@(foreach ($group in ($samples | Group-Object Key)) {
    $first=$group.Group[0]; $last=$group.Group[-1]
    $seconds=$last.ElapsedSeconds-$first.ElapsedSeconds
    $cpuPercent=$null
    if ($seconds -gt 0 -and $last.CpuSeconds -ge $first.CpuSeconds) {
        $cpuPercent=100*($last.CpuSeconds-$first.CpuSeconds)/$seconds
    }
    [pscustomobject]@{
        Name=$first.Name; Id=$first.Id; Samples=$group.Count
        DurationSeconds=[Math]::Round($seconds,3)
        CpuPercentOneCore=$(if ($null -ne $cpuPercent) { [Math]::Round($cpuPercent,4) } else { $null })
        CpuPercentMachine=$(if ($null -ne $cpuPercent) { [Math]::Round($cpuPercent/$logicalProcessors,4) } else { $null })
        WorkingSetMiBMean=[Math]::Round(($group.Group | Measure-Object WorkingSetBytes -Average).Average/1MB,3)
        PrivateMiBMean=[Math]::Round(($group.Group | Measure-Object PrivateBytes -Average).Average/1MB,3)
        PrivateMiBDelta=[Math]::Round(($last.PrivateBytes-$first.PrivateBytes)/1MB,3)
        HandlesFirst=$first.Handles; HandlesLast=$last.Handles
        ThreadsFirst=$first.Threads; ThreadsLast=$last.Threads
    }
})
$report=[pscustomobject]@{
    StartedUtc=$started; Scenario=$Scenario; SessionId=$session
    LogicalProcessors=$logicalProcessors; RequestedDurationSeconds=$DurationSeconds
    Note='Process totals, not isolated Open-Shell cost. Working set includes shared pages; private bytes are committed memory, not resident RAM. CPU uses elapsed time and cumulative process CPU; no opening latency is measured.'
    Processes=@($processInfo.Values); Summary=$summary; Samples=$samples.ToArray()
}
$destination=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$null=New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($destination)) -Force
$report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $destination -Encoding UTF8
$summary | Select-Object Name,Id,CpuPercentMachine,WorkingSetMiBMean,PrivateMiBMean,HandlesLast,ThreadsLast | Format-Table -AutoSize
Write-Host "Performance sample: $destination"
