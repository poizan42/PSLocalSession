<#
.SYNOPSIS
    Exercises a Windows PowerShell 5.1 target session.

.DESCRIPTION
    Run this from Windows PowerShell 5.1 to test a 5.1-to-5.1 session, or from
    PowerShell 7.1+ to test a newer caller against a 5.1 target. The caller and target
    use the default IPC pipe clone path because 5.1 has no custom-pipe-name connection.
#>
[CmdletBinding()]
param(
    [string]$ModulePath,
    [string]$PowerShellPath
)

$ErrorActionPreference = 'Stop'
if (-not $ModulePath) {
    $ModulePath = Join-Path $PSScriptRoot '..\PSLocalSession.psd1'
}
Import-Module $ModulePath -Force

if (-not $PowerShellPath) {
    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        $PowerShellPath = Join-Path $PSHOME 'powershell.exe'
    }
    else {
        $PowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
}

$session = $null
$targetPid = 0
try {
    $session = New-LocalPSSession -CurrentUser -NoProfile `
        -PowerShellPath $PowerShellPath -StartupTimeoutSeconds 60
    $targetPid = [int]$session.LocalPSSessionProcessId
    $info = Invoke-Command -Session $session -ScriptBlock {
        [pscustomobject]@{
            Version  = $PSVersionTable.PSVersion.ToString()
            Edition  = $PSVersionTable.PSEdition
            Pid      = $PID
            UserName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }
    }

    [pscustomobject]@{
        CallerVersion  = $PSVersionTable.PSVersion.ToString()
        CallerEdition  = $PSVersionTable.PSEdition
        TargetVersion  = $info.Version
        TargetEdition  = $info.Edition
        TargetPid      = $info.Pid
        TargetUser     = $info.UserName
        ConnectionMode = $session.LocalPSSessionConnectionMode
        LaunchMethod   = $session.LocalPSSessionLaunchMethod
    } | Format-List

    if ($info.Edition -ne 'Desktop' -or $info.Version -notmatch '^5\.1\.') {
        throw "The target is not Windows PowerShell 5.1: $($info.Version) $($info.Edition)"
    }
    if ($info.Pid -ne $targetPid) {
        throw "PID mismatch: expected $targetPid, got $($info.Pid)"
    }
    if ($session.LocalPSSessionConnectionMode -ne 'Default') {
        throw "Expected the default IPC pipe mode, got $($session.LocalPSSessionConnectionMode)."
    }

    Write-Host 'PowerShell 5.1 target session works.' -ForegroundColor Green
}
finally {
    if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    if ($targetPid) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ((Get-Process -Id $targetPid -ErrorAction SilentlyContinue) -and
               [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }
        if (Get-Process -Id $targetPid -ErrorAction SilentlyContinue) {
            Stop-Process -Id $targetPid -Force -ErrorAction SilentlyContinue
        }
    }
}
