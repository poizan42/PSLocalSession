<#
.SYNOPSIS
    Exercises New-LocalPSSession against another account.

.DESCRIPTION
    Run this once from an elevated PowerShell window (scheduled-task / batch logon) and
    once from a non-elevated window (CreateProcessWithLogonW / interactive logon). The
    target account is the same in both cases; only the launch path changes.

    The script prints the caller and target identities, runs commands through the
    returned PSSession, writes a file in the target's own TEMP directory, and verifies
    that removing the PSSession shuts the target process down.
#>
[CmdletBinding()]
param(
    [pscredential]$Credential = (Get-Credential -Message 'Account to run the target session as'),
    [switch]$NoProfile
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\PSLocalSession.psd1') -Force

$caller = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$callerElevated = [System.Security.Principal.WindowsPrincipal]::new($caller).IsInRole(
    [System.Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host "Caller:   $($caller.Name)"
Write-Host "Elevated: $callerElevated"
Write-Host "Target:   $($Credential.UserName)"
Write-Host ''

$session = $null
$targetProcessId = 0
try {
    $session = New-LocalPSSession -Credential $Credential -NoProfile:$NoProfile -Verbose
    $targetProcessId = [int]$session.LocalPSSessionProcessId

    Write-Host "Session:  $($session.Name) ($($session.Transport))"
    Write-Host "Launch:   $($session.LocalPSSessionLaunchMethod)"
    Write-Host "Target PID: $targetProcessId"
    Write-Host ''

    $result = Invoke-Command -Session $session -ScriptBlock {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [System.Security.Principal.WindowsPrincipal]::new($identity)
        $probe = Join-Path $env:TEMP ('PSLocalSession-probe-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        try {
            'probe' | Set-Content -LiteralPath $probe -ErrorAction Stop
            $tempWritable = (Get-Content -LiteralPath $probe -Raw).Trim() -eq 'probe'
        }
        finally {
            Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        }

        [pscustomobject]@{
            UserName       = $identity.Name
            ProcessId      = $PID
            IsElevated     = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
            UserProfile    = $env:USERPROFILE
            Home           = $HOME
            TempWritable   = $tempWritable
            PowerShell     = $PSVersionTable.PSVersion.ToString()
        }
    }

    $result | Format-List

    $expected = $Credential.UserName
    $actual = $result.UserName
    $sameUser = $actual -ieq $expected -or
        ($expected -match '^(?<domain>[^\\@]+)\\(?<name>.+)$' -and
         $actual -ieq ('{0}\{1}' -f $Matches['domain'], $Matches['name']))
    if (-not $sameUser) {
        Write-Warning "The target reports '$actual'; the supplied credential was '$expected'. " +
            'This is normally only a display-name difference.'
    }

    if ($result.ProcessId -ne $targetProcessId) {
        throw "PID mismatch: session metadata says $targetProcessId, target reports $($result.ProcessId)."
    }
    if (-not $result.TempWritable) {
        throw "The target could not write to its own TEMP directory."
    }

    Write-Host ''
    Write-Host 'Target session works.' -ForegroundColor Green
}
finally {
    if ($session) {
        Write-Host "Removing the session and waiting for target PID $targetProcessId to exit..."
        Remove-PSSession -Session $session -ErrorAction SilentlyContinue
    }

    if ($targetProcessId) {
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ((Get-Process -Id $targetProcessId -ErrorAction SilentlyContinue) -and
               [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 200
        }

        if (Get-Process -Id $targetProcessId -ErrorAction SilentlyContinue) {
            Write-Warning "Target process $targetProcessId did not exit; stopping it."
            Stop-Process -Id $targetProcessId -Force -ErrorAction SilentlyContinue
        }
        else {
            Write-Host "Target process $targetProcessId exited." -ForegroundColor Green
        }
    }
}
