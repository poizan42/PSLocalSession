<#
.SYNOPSIS
    Exercises New-LocalPSSession with the built-in passwordless accounts.

.DESCRIPTION
    Run this from an elevated PowerShell window (or LocalSystem). For each selected
    account, it starts a session through Task Scheduler's ServiceAccount logon, verifies
    the target SID, PID, TEMP, and launch metadata, then removes the session and waits for
    the target process to exit.

    Use -PowerShellPath to test a Windows PowerShell 5.1 target from a 7.1+ caller, or a
    7.1+ target from a 5.1 caller.

.PARAMETER Identity
    Built-in account names to test. Defaults to SYSTEM, LOCAL SERVICE, and NETWORK SERVICE.

.PARAMETER PowerShellPath
    Target executable. Defaults to the current PowerShell installation.

.PARAMETER RunLevel
    Task run level to request: Highest (default) or Limited.

.PARAMETER LoadProfile
    Load the target profile. By default the script passes -NoProfile for a deterministic
    service-account startup.
#>
[CmdletBinding()]
param(
    [string[]]$Identity = @(
        'NT AUTHORITY\SYSTEM'
        'NT AUTHORITY\LOCAL SERVICE'
        'NT AUTHORITY\NETWORK SERVICE'
    ),
    [string]$PowerShellPath,
    [ValidateSet('Highest', 'Limited')]
    [string]$RunLevel = 'Highest',
    [switch]$LoadProfile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\PSLocalSession.psd1') -Force

$caller = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$elevated = if ($caller.User.Value -eq 'S-1-5-18') {
    $true
}
else {
    [System.Security.Principal.WindowsPrincipal]::new($caller).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not $elevated) {
    throw 'Run this script from an elevated PowerShell window or as LocalSystem.'
}

$expectedSids = @{
    'NT AUTHORITY\SYSTEM'          = 'S-1-5-18'
    'NT AUTHORITY\LOCAL SERVICE'   = 'S-1-5-19'
    'NT AUTHORITY\NETWORK SERVICE' = 'S-1-5-20'
}

Write-Host "Caller:   $($caller.Name)"
Write-Host "Elevated: $elevated"
Write-Host ''

$results = [System.Collections.Generic.List[object]]::new()
$failures = [System.Collections.Generic.List[string]]::new()

foreach ($account in $Identity) {
    Write-Host "Testing $account..."
    $session = $null
    $targetPid = 0
    $row = [ordered]@{
        Identity       = $account
        CanonicalName  = $null
        Sid            = $null
        ExpectedSid    = $null
        LaunchMethod   = $null
        RunLevel       = $null
        ConnectionMode = $null
        TargetPid      = $null
        Edition        = $null
        PowerShell     = $null
        Temp           = $null
        TempWritable   = $null
        Result         = 'FAIL'
    }

    $rowFailures = [System.Collections.Generic.List[string]]::new()

    try {
        $sessionParameters = @{
            Identity             = $account
            StartupTimeoutSeconds = 60
            RunLevel             = $RunLevel
            NoProfile            = -not $LoadProfile
        }
        if ($PowerShellPath) {
            $sessionParameters['PowerShellPath'] = $PowerShellPath
        }
        $session = New-LocalPSSession @sessionParameters -Verbose
        $targetPid = [int]$session.LocalPSSessionProcessId

        $info = Invoke-Command -Session $session -ScriptBlock {
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $tempDirectory = [System.IO.Path]::GetTempPath()
            $probe = Join-Path $tempDirectory (
                'PSLocalSession-probe-{0}.txt' -f [guid]::NewGuid().ToString('N'))
            try {
                'probe' | Set-Content -LiteralPath $probe -ErrorAction Stop
                $tempWritable = (Get-Content -LiteralPath $probe -Raw).Trim() -eq 'probe'
            }
            finally {
                Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
            }

            [pscustomobject]@{
                UserName     = $identity.Name
                Sid          = $identity.User.Value
                ProcessId    = $PID
                Edition      = $PSVersionTable.PSEdition
                PowerShell   = $PSVersionTable.PSVersion.ToString()
                Temp         = $tempDirectory
                TempWritable = $tempWritable
            }
        }

        $row.CanonicalName = $info.UserName
        $row.Sid = $info.Sid
        $row.ExpectedSid = $expectedSids[$info.UserName]
        $row.LaunchMethod = $session.LocalPSSessionLaunchMethod
        $row.RunLevel = $session.LocalPSSessionRunLevel
        $row.ConnectionMode = $session.LocalPSSessionConnectionMode
        $row.TargetPid = $targetPid
        $row.Edition = $info.Edition
        $row.PowerShell = $info.PowerShell
        $row.Temp = $info.Temp
        $row.TempWritable = $info.TempWritable

        if (-not $row.ExpectedSid) {
            $rowFailures.Add("$account resolved to unexpected account '$($info.UserName)'.")
        }
        elseif ($info.Sid -ne $row.ExpectedSid) {
            $rowFailures.Add("$account expected SID $($row.ExpectedSid), got $($info.Sid).")
        }
        if ($info.ProcessId -ne $targetPid) {
            $rowFailures.Add("$account PID mismatch: session says $targetPid, target says $($info.ProcessId).")
        }
        if ($session.LocalPSSessionLaunchMethod -ne 'ScheduledTask') {
            $rowFailures.Add("$account used launch method '$($session.LocalPSSessionLaunchMethod)'.")
        }
        if ($RunLevel -eq 'Limited' -and $session.LocalPSSessionRunLevel -ne 'Limited') {
            $rowFailures.Add("$account requested Limited but used '$($session.LocalPSSessionRunLevel)'.")
        }
        if (-not $info.TempWritable) {
            $rowFailures.Add("$account could not write to TEMP '$($info.Temp)'.")
        }

        if ($rowFailures.Count -eq 0) {
            $row.Result = 'PASS'
        }
    }
    catch {
        $rowFailures.Add("$account failed: $($_.Exception.Message)")
    }
    finally {
        if ($session) {
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
        if ($targetPid) {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while ((Get-Process -Id $targetPid -ErrorAction SilentlyContinue) -and
                   [DateTime]::UtcNow -lt $deadline) {
                Start-Sleep -Milliseconds 200
            }
            if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
                $rowFailures.Add("$account target process $targetPid did not exit; stopping it.")
                Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
            }
        }
    }

    foreach ($rowFailure in $rowFailures) {
        $failures.Add($rowFailure)
    }
    $results.Add([pscustomobject]$row)
    Write-Host ''
}

$results | Format-Table -AutoSize

if ($failures.Count -gt 0) {
    Write-Host 'Failures:' -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host 'All built-in service account sessions work.' -ForegroundColor Green
