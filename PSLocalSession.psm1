#Requires -Version 5.1

Set-StrictMode -Version Latest

$script:TaskPath = '\PSLocalSession\'
$script:BootstrapConnectTimeoutSeconds = 60
$script:ControlMessageTimeoutMs = 30000
$script:RunspaceTypeTable = $null

# The target-side bootstrap and C# pipe helpers are separate files next to this
# module so the target can execute a static script by path and antivirus software can
# inspect both the script and the C# source.
$script:BootstrapScriptPath = Join-Path $PSScriptRoot 'PSLocalSession.Bootstrap.ps1'
$script:BootstrapSupportFiles = @(
    'PSLocalSession.Bootstrap.ps1'
    'PSLocalSession.PipeServer.Core.cs'
    'PSLocalSession.PipeServer.Desktop.cs'
)


#region General helpers

function Test-PSLocalSessionElevated {
    <# .SYNOPSIS Whether the current token is an elevated administrator token. #>
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    if ($identity.User.Value -eq 'S-1-5-18') {
        # LocalSystem is not a member of Administrators, but it is fully privileged.
        return $true
    }
    return [System.Security.Principal.WindowsPrincipal]::new($identity).IsInRole(
        [System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-PSLocalSessionUser {
    <# .SYNOPSIS Resolves a user name to its canonical DOMAIN\name form and SID. #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$UserName
    )

    $normalized = $UserName
    if ($normalized.StartsWith('.\')) {
        $normalized = '{0}\{1}' -f $env:COMPUTERNAME, $normalized.Substring(2)
    }

    try {
        $account = [System.Security.Principal.NTAccount]::new($normalized)
        $sid = $account.Translate([System.Security.Principal.SecurityIdentifier])
    }
    catch {
        throw ("Cannot resolve the account '{0}': {1}" -f $UserName, $_.Exception.Message)
    }

    $canonical = $normalized
    try {
        $canonical = $sid.Translate([System.Security.Principal.NTAccount]).Value
    }
    catch {
        Write-Verbose "Could not translate SID $($sid.Value) back to a name; using '$normalized'."
    }

    return [pscustomobject]@{
        UserName     = $canonical
        Sid          = $sid
        IsCurrentUser = $sid.Value -eq [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
}

function Resolve-PSLocalSessionBuiltInIdentity {
    <#  .SYNOPSIS Resolves a built-in passwordless account to its canonical name and SID.

        Task Scheduler can run a task directly as SYSTEM, LOCAL SERVICE, or NETWORK SERVICE
        with a ServiceAccount principal. Those accounts have no password, so -Credential
        cannot carry them. Other passwordless account types are not supported. #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Identity
    )

    $value = $Identity.Trim()
    $key = $value.ToUpperInvariant()
    $accounts = @{
        'S-1-5-18'                     = 'NT AUTHORITY\SYSTEM'
        'SYSTEM'                       = 'NT AUTHORITY\SYSTEM'
        'LOCALSYSTEM'                  = 'NT AUTHORITY\SYSTEM'
        'NT AUTHORITY\SYSTEM'          = 'NT AUTHORITY\SYSTEM'
        'NT AUTHORITY\LOCALSYSTEM'     = 'NT AUTHORITY\SYSTEM'
        'S-1-5-19'                     = 'NT AUTHORITY\LOCAL SERVICE'
        'LOCAL SERVICE'                = 'NT AUTHORITY\LOCAL SERVICE'
        'LOCALSERVICE'                 = 'NT AUTHORITY\LOCAL SERVICE'
        'NT AUTHORITY\LOCAL SERVICE'   = 'NT AUTHORITY\LOCAL SERVICE'
        'NT AUTHORITY\LOCALSERVICE'    = 'NT AUTHORITY\LOCAL SERVICE'
        'S-1-5-20'                     = 'NT AUTHORITY\NETWORK SERVICE'
        'NETWORK SERVICE'              = 'NT AUTHORITY\NETWORK SERVICE'
        'NETWORKSERVICE'               = 'NT AUTHORITY\NETWORK SERVICE'
        'NT AUTHORITY\NETWORK SERVICE' = 'NT AUTHORITY\NETWORK SERVICE'
        'NT AUTHORITY\NETWORKSERVICE'  = 'NT AUTHORITY\NETWORK SERVICE'
    }

    if ($accounts.ContainsKey($key)) {
        # Do not use the supplied spelling: Task Scheduler and the pipe ACLs use the
        # canonical account name and SID.
        return Resolve-PSLocalSessionUser -UserName $accounts[$key]
    }

    if ($key -like 'NT SERVICE\*') {
        throw (("'{0}' is an NT SERVICE virtual account. Task Scheduler cannot run a task " +
                "as it; create a service that runs as it instead.") -f $Identity)
    }
    if ($key -like 'NT TASK\*') {
        throw (("'{0}' is an NT TASK virtual account. It can only be used by the scheduled " +
                "task that owns it.") -f $Identity)
    }
    if ($key -like 'IIS APPPOOL\*' -or $key -like 'NT VIRTUAL MACHINE\*' -or
        $key -like 'WINDOW MANAGER\*' -or $key -like 'FONT DRIVER HOST\*') {
        throw (("'{0}' is a Windows virtual account. Virtual accounts are not supported by " +
                "New-LocalPSSession.") -f $Identity)
    }

    throw (("'{0}' is not a built-in passwordless account. Use -Credential for an account " +
            "with a password. -Identity accepts NT AUTHORITY\SYSTEM, " +
            "NT AUTHORITY\LOCAL SERVICE, or NT AUTHORITY\NETWORK SERVICE.") -f $Identity)
}

function Get-PSLocalSessionPowerShellPath {
    <# .SYNOPSIS Locates the PowerShell executable used to host the target session. #>
    [OutputType([string])]
    [CmdletBinding()]
    param([string]$Path)

    if ($Path) {
        $resolved = Resolve-Path -LiteralPath $Path -ErrorAction Stop
        if (-not (Test-Path -LiteralPath $resolved.Path -PathType Leaf)) {
            throw "The PowerShell path '$Path' is not a file."
        }
        return $resolved.Path
    }

    if (-not $PSHOME) {
        throw 'Cannot determine $PSHOME for the current PowerShell host.'
    }

    $executable = if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' }
    $candidate = [System.IO.Path]::Combine($PSHOME, $executable)
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw ("Cannot find {0} at '{1}'. Use -PowerShellPath to point at a shared " +
               "PowerShell 5.1 or 7.1+ installation the target account can read." -f
               $executable, $candidate)
    }
    return $candidate
}

function ConvertTo-PSLocalSessionCommandLineArgument {
    <# .SYNOPSIS Quotes one argument for a Windows command line. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Argument
    )

    if ($Argument -ne '' -and $Argument -notmatch '[\s"]') { return $Argument }

    $builder = [System.Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $backslashes = 0
    foreach ($ch in $Argument.ToCharArray()) {
        if ($ch -eq '\') {
            $backslashes++
            continue
        }
        if ($ch -eq '"') {
            [void]$builder.Append([char]'\', $backslashes * 2 + 1)
            [void]$builder.Append('"')
        }
        else {
            [void]$builder.Append([char]'\', $backslashes)
            [void]$builder.Append($ch)
        }
        $backslashes = 0
    }
    [void]$builder.Append([char]'\', $backslashes * 2)
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-PSLocalSessionCommandLine {
    <# .SYNOPSIS Joins arguments into one Windows command-line string. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [AllowEmptyCollection()]
        [string[]]$ArgumentList
    )

    if (-not $ArgumentList) { return '' }
    return (($ArgumentList | ForEach-Object {
        ConvertTo-PSLocalSessionCommandLineArgument -Argument $_
    }) -join ' ')
}

function New-PSLocalSessionPipe {
    <# .SYNOPSIS Creates a local named-pipe server with an ACL for caller and target. #>
    [OutputType([System.IO.Pipes.NamedPipeServerStream])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$CallerSid,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TargetSid,
        [System.IO.Pipes.PipeDirection]$Direction = [System.IO.Pipes.PipeDirection]::InOut,
        [int]$InBufferSize = 4096,
        [int]$OutBufferSize = 4096
    )

    $security = [System.IO.Pipes.PipeSecurity]::new()
    $security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
        $CallerSid,
        [System.IO.Pipes.PipeAccessRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow))
    if ($TargetSid.Value -ne $CallerSid.Value) {
        $security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
            $TargetSid,
            [System.IO.Pipes.PipeAccessRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow))
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        # .NET Framework has the PipeSecurity constructor directly.
        return [System.IO.Pipes.NamedPipeServerStream]::new(
            $PipeName,
            $Direction,
            1,
            [System.IO.Pipes.PipeTransmissionMode]::Byte,
            [System.IO.Pipes.PipeOptions]::Asynchronous,
            $InBufferSize,
            $OutBufferSize,
            $security)
    }

    return [System.IO.Pipes.NamedPipeServerStreamAcl]::Create(
        $PipeName,
        $Direction,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous,
        $InBufferSize,
        $OutBufferSize,
        $security)
}

function New-PSLocalSessionControlPipe {
    <# .SYNOPSIS Creates the short-lived startup/identity pipe used by the target. #>
    [OutputType([System.IO.Pipes.NamedPipeServerStream])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$CallerSid,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TargetSid
    )

    return New-PSLocalSessionPipe -PipeName $PipeName `
        -CallerSid $CallerSid -TargetSid $TargetSid
}

function Test-PSLocalSessionEffectiveAccess {
    <#  .SYNOPSIS Checks a target SID's effective access to a file-system path.

        Uses GetEffectiveRightsFromAclW through a small native helper. This evaluates the
        DACL without needing a token for the target account. Any failure is treated as
        "cannot read", which falls back to a target-readable copy. #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TargetSid,
        [Parameter(Mandatory)][long]$RequiredMask
    )

    try {
        $accessCheck = 'PSLocalSession.Native.FileAccessCheck' -as [type]
        if (-not $accessCheck) {
            Add-Type -Path (Join-Path $PSScriptRoot 'PSLocalSession.AccessCheck.cs') `
                -ErrorAction Stop
            $accessCheck = 'PSLocalSession.Native.FileAccessCheck' -as [type]
        }
        if (-not $accessCheck) { return $false }

        $effective = $accessCheck::GetEffectiveRights($Path, $TargetSid.Value)
        return ($effective -ge 0 -and (($effective -band $RequiredMask) -eq $RequiredMask))
    }
    catch {
        return $false
    }
}

function Test-PSLocalSessionPathUnderProfile {
    <# .SYNOPSIS Whether a path is inside the caller's user profile. #>
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $profile = [Environment]::GetFolderPath('UserProfile')
    if ([string]::IsNullOrEmpty($profile)) { return $false }
    $prefix = $profile.TrimEnd('\') + '\'
    return [System.IO.Path]::GetFullPath($Path).StartsWith(
        $prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Test-PSLocalSessionTargetCanRead {
    <# .SYNOPSIS Whether the target can read the module bootstrap and pipe helpers. #>
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BootstrapScriptPath,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TargetSid
    )

    $moduleDirectory = Split-Path -Parent $BootstrapScriptPath
    $files = @($BootstrapScriptPath)
    foreach ($name in 'PSLocalSession.PipeServer.Core.cs',
                      'PSLocalSession.PipeServer.Desktop.cs') {
        $files += Join-Path $moduleDirectory $name
    }

    # FILE_READ_DATA | FILE_READ_ATTRIBUTES, then FILE_TRAVERSE | FILE_READ_ATTRIBUTES
    # on every parent directory. All files share the same parent chain.
    $checkedDirectories = @{}
    foreach ($file in $files) {
        if (-not (Test-PSLocalSessionEffectiveAccess -Path $file -TargetSid $TargetSid `
                    -RequiredMask 0x81)) {
            return $false
        }

        $directory = Split-Path -Parent $file
        while ($directory) {
            if (-not $checkedDirectories.ContainsKey($directory)) {
                if (-not (Test-PSLocalSessionEffectiveAccess -Path $directory `
                            -TargetSid $TargetSid -RequiredMask 0xA0)) {
                    return $false
                }
                $checkedDirectories[$directory] = $true
            }
            $parent = Split-Path -Parent $directory
            if ($parent -eq $directory) { break }
            $directory = $parent
        }
    }
    return $true
}

function Copy-PSLocalSessionBootstrapFiles {
    <#  .SYNOPSIS Copies the static bootstrap and pipe helpers to a target-readable directory.

        The target account may not be able to traverse the caller's profile. A copy under
        ProgramData gets an explicit caller/target DACL, so the target can read the script
        and C# sources without broadening access to the module directory. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$CallerSid,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$TargetSid
    )

    $commonData = [Environment]::GetFolderPath('CommonApplicationData')
    if ([string]::IsNullOrEmpty($commonData)) { $commonData = $env:ProgramData }

    # Create a unique directory directly under ProgramData so there are no intermediate
    # directories that could carry a previous target's ACL. The target only reads these
    # files during startup, so old directories are safe to remove.
    Get-ChildItem -LiteralPath $commonData -Directory -Filter 'PSLocalSession-*' `
            -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddDays(-1) } |
        ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
            catch { }
        }

    $staging = Join-Path $commonData ('PSLocalSession-{0}' -f [guid]::NewGuid().ToString('N'))
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
        $CallerSid,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $inheritance,
        $propagation,
        [System.Security.AccessControl.AccessControlType]::Allow))
    if ($TargetSid.Value -ne $CallerSid.Value) {
        $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
            $TargetSid,
            [System.Security.AccessControl.FileSystemRights]::ReadAndExecute,
            $inheritance,
            $propagation,
            [System.Security.AccessControl.AccessControlType]::Allow))
    }

    if ($PSVersionTable.PSEdition -eq 'Desktop') {
        [void][System.IO.Directory]::CreateDirectory($staging, $security)
    }
    else {
        [void][System.IO.FileSystemAclExtensions]::CreateDirectory($security, $staging)
    }

    try {
        foreach ($name in $script:BootstrapSupportFiles) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) `
                -Destination (Join-Path $staging $name) -Force -ErrorAction Stop
        }
    }
    catch {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    return $staging
}

function New-PSLocalSessionBootstrapArguments {
    <# .SYNOPSIS Builds the per-session arguments passed to the static bootstrap script. #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][string]$ControlPipeName,
        [Parameter(Mandatory)][string]$CallerSid,
        [Parameter(Mandatory)][int]$ConnectTimeoutSeconds,
        [Parameter(Mandatory)][bool]$CallerIsDesktop
    )

    return @(
        '-PipeName', $PipeName
        '-ControlPipeName', $ControlPipeName
        '-CallerSid', $CallerSid
        '-ConnectTimeoutSeconds', [string]$ConnectTimeoutSeconds
        '-CallerIsDesktop', $(if ($CallerIsDesktop) { '1' } else { '0' })
    )
}

function New-PSLocalSessionTargetArguments {
    <# .SYNOPSIS Builds the target command-line arguments for the static bootstrap script. #>
    [OutputType([string[]])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BootstrapScriptPath,
        [Parameter(Mandatory)][string[]]$BootstrapArguments,
        [switch]$NoProfile
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoLogo')
    $arguments.Add('-NonInteractive')
    if ($NoProfile) { $arguments.Add('-NoProfile') }
    $arguments.Add('-ExecutionPolicy')
    $arguments.Add('Bypass')
    $arguments.Add('-File')
    $arguments.Add($BootstrapScriptPath)
    foreach ($argument in $BootstrapArguments) {
        $arguments.Add($argument)
    }
    return $arguments.ToArray()
}
#endregion


#region Diagnostics

function Get-PSLocalSessionLogonErrorHint {
    <# .SYNOPSIS Turns a Win32 logon failure into an actionable hint. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Exception]$Exception,
        [Parameter(Mandatory)][ValidateSet('Batch', 'Interactive', 'Service')][string]$LogonPath
    )

    $inner = $Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }

    $code = $null
    if ($inner.PSObject.Properties.Name -contains 'NativeErrorCode') {
        $code = $inner.NativeErrorCode
    }
    elseif ($inner.PSObject.Properties.Name -contains 'ErrorCode') {
        $code = $inner.ErrorCode -band 0xFFFF
    }

    switch ($code) {
        1385 {
            if ($LogonPath -eq 'Batch') {
                return ("The account lacks the 'Log on as a batch job' right (or is denied it). " +
                        "Grant it in Local Security Policy > User Rights Assignment, or run " +
                        "New-LocalPSSession from a non-elevated prompt to use an interactive logon instead.")
            }
            if ($LogonPath -eq 'Service') {
                return ("The account lacks the 'Log on as a service' right (or is denied it). " +
                        "Built-in service accounts normally have it; check Local Security Policy > " +
                        "User Rights Assignment if it was removed.")
            }
            return ("The account is denied 'Log on locally', which this path requires. Run " +
                    "New-LocalPSSession from an elevated prompt so the scheduled-task path can be " +
                    "used, or grant the account 'Log on locally'.")
        }
        1312 { return ("No such logon session. The 'Network access: Do not allow storage of " +
                       "passwords and credentials for network authentication' policy (DisableDomainCreds) " +
                       "blocks stored-password scheduled tasks.") }
        1326 { return 'The user name or password is incorrect.' }
        1330 { return "The account's password has expired." }
        1331 { return 'The account is disabled.' }
        1909 { return 'The account is locked out.' }
        1058 { return ("The Secondary Logon service is disabled. The interactive fallback needs it; " +
                       "enable that service, or run New-LocalPSSession elevated to use the " +
                       "scheduled-task path.") }
        default { return $null }
    }
}

function Get-PSLocalSessionTaskResultHint {
    <# .SYNOPSIS Decodes a scheduled task's LastTaskResult. #>
    [OutputType([string])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Code)

    switch ($Code) {
        0x00000000 { return 'the task ran and exited successfully' }
        0x00000001 { return 'the program itself failed; check that the target can read pwsh.exe and start it' }
        0x00000002 { return 'the executable was not found' }
        0x0000000D { return 'the task XML is malformed' }
        0x000005B4 { return 'the task timed out' }
        0x00041300 { return 'the task is registered but has not run' }
        0x00041301 { return 'the task is still running' }
        0x00041302 { return 'the task was disabled' }
        0x00041303 { return 'the task has never run' }
        0x00041306 { return 'the task was terminated' }
        0x8004130F { return 'no account information could be found; the task logon information did not take' }
        0x80070005 { return 'access denied' }
        0x80070569 {
            return ("the account lacks the requested logon right (batch for -Credential, " +
                    "service for -Identity) or is explicitly denied it")
        }
        0x8007052E { return 'the user name or password is incorrect' }
        0x80070532 { return "the account's password has expired" }
        0x80070533 { return 'the account is disabled' }
        0x800704DD { return 'the task account is not logged on; check the logon type and stored credentials' }
        0x80070775 { return 'the account is locked out' }
        default { return $null }
    }
}

#endregion


#region Launching the target

function Start-PSLocalSessionProcess {
    <#  .SYNOPSIS Starts the target PowerShell executable directly, optionally as
        another user via CreateProcessWithLogonW.

        The target runs the static bootstrap script by path with per-session arguments.
        The command line stays well under CreateProcessWithLogonW's 1024-character
        limit. #>
    [OutputType([System.Diagnostics.Process])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$BootstrapScriptPath,
        [Parameter(Mandatory)][string[]]$BootstrapArguments,
        [pscredential]$Credential,
        [switch]$NoProfile
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PowerShellPath
    $arguments = @(New-PSLocalSessionTargetArguments -BootstrapScriptPath $BootstrapScriptPath `
        -BootstrapArguments $BootstrapArguments -NoProfile:$NoProfile)
    if ([System.Diagnostics.ProcessStartInfo].GetProperty('ArgumentList')) {
        foreach ($argument in $arguments) {
            [void]$startInfo.ArgumentList.Add($argument)
        }
    }
    else {
        $startInfo.Arguments = ConvertTo-PSLocalSessionCommandLine -ArgumentList $arguments
    }

    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.WorkingDirectory = [System.IO.Path]::Combine($env:SystemRoot, 'System32')

    if ($Credential) {
        $name = $Credential.UserName
        if ($name -match '^(?<domain>[^\\@]+)\\(?<user>.+)$') {
            $domain = $Matches['domain']
            if ($domain -eq '.') { $domain = $env:COMPUTERNAME }
            $startInfo.Domain = $domain
            $startInfo.UserName = $Matches['user']
        }
        else {
            # UPN or a bare local name. CreateProcessWithLogonW accepts a UPN with no domain.
            $startInfo.UserName = $name
        }
        $startInfo.Password = $Credential.Password
        $startInfo.LoadUserProfile = $true
    }

    $process = $null
    $displayUser = if ($Credential) {
        $Credential.UserName
    }
    else {
        [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    }
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        return $process
    }
    catch {
        if ($process) {
            if (-not $process.HasExited) {
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            $process.Dispose()
        }

        $hint = Get-PSLocalSessionLogonErrorHint -Exception $_.Exception -LogonPath 'Interactive'
        if ($hint) {
            throw ("Could not start PowerShell as '{0}': {1}" -f $displayUser, $hint)
        }
        throw ("Could not start PowerShell as '{0}': {1}" -f $displayUser, $_.Exception.Message)
    }
}

function Remove-OrphanedPSLocalSessionTask {
    <# .SYNOPSIS Removes stale session tasks left by a caller that was killed. #>
    [CmdletBinding()]
    param([int]$GraceMinutes = 10)

    $tasks = @(Get-ScheduledTask -TaskPath $script:TaskPath -ErrorAction SilentlyContinue |
        Where-Object { $_.TaskName -like 'session-*' })

    foreach ($task in $tasks) {
        if ($task.State -eq 'Running') { continue }

        $registered = $null
        if ($task.Date) {
            try { $registered = [DateTime]::Parse($task.Date) } catch { $registered = $null }
        }
        if ($registered -and $registered -gt [DateTime]::Now.AddMinutes(-$GraceMinutes)) { continue }

        Write-Verbose "Removing orphaned session task $($task.TaskName)"
        try {
            Unregister-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath `
                -Confirm:$false -ErrorAction Stop
        }
        catch {
            Write-Warning "Could not remove orphaned session task $($task.TaskName): $($_.Exception.Message)"
        }
    }
}

function Test-PSLocalSessionAccessDeniedError {
    <# .SYNOPSIS Whether a task-registration failure is a permission problem. #>
    [OutputType([bool])]
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Exception]$Exception)

    $inner = $Exception
    while ($inner.InnerException) { $inner = $inner.InnerException }
    try {
        $hresult = [uint32]([int64]$inner.HResult -band [int64]4294967295)
    }
    catch {
        $hresult = 0
    }
    if ($hresult -eq 0x80070005 -or $hresult -eq 0x80070522) {
        return $true
    }
    return ($inner.Message -match 'Access is denied|Access denied')
}

function New-PSLocalSessionTaskPrincipal {
    <#  .SYNOPSIS Builds a scheduled-task principal that stores no password.

        ServiceAccount is Task Scheduler's logon type for built-in service accounts;
        Interactive exists for the test-only interactive-token path. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TargetUserName,
        [Parameter(Mandatory)]
        [ValidateSet('Interactive', 'ServiceAccount')]
        [string]$LogonType,
        [Parameter(Mandatory)]
        [ValidateSet('Highest', 'Limited')]
        [string]$RunLevel
    )

    return New-ScheduledTaskPrincipal -UserId $TargetUserName -LogonType $LogonType `
        -RunLevel $RunLevel -ErrorAction Stop
}

function Start-PSLocalSessionScheduledTask {
    <#  .SYNOPSIS Starts the target PowerShell through Task Scheduler.

        The production path uses a stored password and therefore a BATCH logon. The
        -InteractiveToken switch exists so tests can exercise the task plumbing without a
        second account's password; it registers the task with an interactive-logon
        principal instead. -Passwordless registers a ServiceAccount principal for a
        built-in passwordless account and never stores a password. #>
    [OutputType([hashtable])]
    [CmdletBinding(DefaultParameterSetName = 'Password')]
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$BootstrapScriptPath,
        [Parameter(Mandatory)][string[]]$BootstrapArguments,
        [Parameter(Mandatory, ParameterSetName = 'Password')][pscredential]$Credential,
        [Parameter(Mandatory)][string]$TargetUserName,
        [Parameter(Mandatory, ParameterSetName = 'Interactive')][switch]$InteractiveToken,
        [Parameter(Mandatory, ParameterSetName = 'Passwordless')][switch]$Passwordless,
        [ValidateSet('Highest', 'Limited')][string]$RunLevel = 'Highest',
        [switch]$NoProfile
    )

    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw "The ScheduledTasks module is not available; the elevated path cannot start a batch-logon process."
    }

    Remove-OrphanedPSLocalSessionTask

    $taskName = 'session-{0}' -f [guid]::NewGuid().ToString('N')
    $arguments = @(New-PSLocalSessionTargetArguments -BootstrapScriptPath $BootstrapScriptPath `
        -BootstrapArguments $BootstrapArguments -NoProfile:$NoProfile)
    $argumentLine = ConvertTo-PSLocalSessionCommandLine -ArgumentList $arguments

    $action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $argumentLine `
        -WorkingDirectory ([System.IO.Path]::Combine($env:SystemRoot, 'System32'))
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Days 1)
    $task = @{
        TaskName         = $taskName
        TaskPath         = $script:TaskPath
        Registered       = $false
        RunLevel         = $null
        StoresCredential = $PSCmdlet.ParameterSetName -eq 'Password'
    }

    $password = $null
    try {
        $levels = if ($RunLevel -eq 'Highest') { @('Highest', 'Limited') } else { @('Limited') }
        foreach ($level in $levels) {
            try {
                if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
                    $principal = New-PSLocalSessionTaskPrincipal -TargetUserName $TargetUserName `
                        -LogonType Interactive -RunLevel $level
                    $null = Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath `
                        -Action $action -Settings $settings -Principal $principal `
                        -Force -ErrorAction Stop
                }
                elseif ($PSCmdlet.ParameterSetName -eq 'Passwordless') {
                    # ServiceAccount tells Task Scheduler to use the account's service logon
                    # without a stored password. There is no -User/-Password pair here.
                    $principal = New-PSLocalSessionTaskPrincipal -TargetUserName $TargetUserName `
                        -LogonType ServiceAccount -RunLevel $level
                    $null = Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath `
                        -Action $action -Settings $settings -Principal $principal `
                        -Force -ErrorAction Stop
                }
                else {
                    $password = $Credential.GetNetworkCredential().Password
                    $null = Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath `
                        -Action $action -Settings $settings -User $TargetUserName -Password $password `
                        -RunLevel $level -Force -ErrorAction Stop
                }
                $task.Registered = $true
                $task.RunLevel = $level
                Start-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath -ErrorAction Stop
                break
            }
            catch {
                if ($level -eq 'Highest' -and
                    (Test-PSLocalSessionAccessDeniedError -Exception $_.Exception)) {
                    Write-Verbose 'Highest run level was denied; retrying with Limited.'
                    continue
                }
                throw
            }
        }
    }
    catch {
        $logonPath = switch ($PSCmdlet.ParameterSetName) {
            'Interactive' { 'Interactive' }
            'Passwordless' { 'Service' }
            default { 'Batch' }
        }
        $hint = Get-PSLocalSessionLogonErrorHint -Exception $_.Exception -LogonPath $logonPath
        if ($task.Registered) {
            try {
                Stop-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath -ErrorAction SilentlyContinue
            }
            catch { }
            try {
                Unregister-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath `
                    -Confirm:$false -ErrorAction SilentlyContinue
            }
            catch { }
        }
        if ($hint) {
            throw ("Could not start PowerShell as '{0}': {1}" -f $TargetUserName, $hint)
        }
        throw ("Could not start PowerShell as '{0}': {1}" -f $TargetUserName, $_.Exception.Message)
    }
    finally {
        $password = $null
    }

    return $task
}

function Unregister-PSLocalSessionScheduledTask {
    <# .SYNOPSIS Removes the task definition while leaving its process running. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Task)

    if (-not $Task.Registered) { return }

    try {
        Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath `
            -Confirm:$false -ErrorAction Stop
        $Task.Registered = $false
    }
    catch {
        $credentialNote = if ($Task.StoresCredential) {
            ' It still holds the stored credential.'
        }
        else {
            ''
        }
        Write-Warning ("The session is running, but its scheduled task '{1}' at '{0}' could not be " +
            "unregistered: {2}{3} Remove it with: " +
            "Unregister-ScheduledTask -TaskName '{1}' -TaskPath '{0}' -Confirm:`$false" -f
            $Task.TaskPath, $Task.TaskName, $_.Exception.Message, $credentialNote)
    }
}

function Stop-PSLocalSessionScheduledTask {
    <# .SYNOPSIS Stops and removes a task that failed before the session was established. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$Task)

    if (-not $Task.Registered) { return }

    try {
        Stop-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath -ErrorAction Stop
    }
    catch {
        Write-Verbose "Stopping session task $($Task.TaskName): $($_.Exception.Message)"
    }

    try {
        Unregister-ScheduledTask -TaskName $Task.TaskName -TaskPath $Task.TaskPath `
            -Confirm:$false -ErrorAction Stop
        $Task.Registered = $false
    }
    catch {
        Write-Warning ("Could not remove session task '{0}{1}': {2}" -f
            $Task.TaskPath, $Task.TaskName, $_.Exception.Message)
    }
}

function Wait-PSLocalSessionControlMessage {
    <# .SYNOPSIS Waits for the target's OK/ERROR startup line. #>
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.IO.Pipes.NamedPipeServerStream]$ControlPipe,
        [Parameter(Mandatory)][System.Threading.Tasks.Task]$ConnectionTask,
        [System.Diagnostics.Process]$Process,
        [scriptblock]$Diagnose,
        # Returns a failure description when the launcher itself has already failed (for
        # example, the scheduled task is no longer running with a logon error). Polled while
        # waiting so a wrong password does not sit for the full timeout.
        [scriptblock]$CheckFailure,
        [int]$TimeoutMs = $script:ControlMessageTimeoutMs
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    # Give Task Scheduler a moment to move the task out of its initial state before
    # treating a non-Running state as a failure.
    $nextFailureCheck = [DateTime]::UtcNow.AddSeconds(2)
    while ($true) {
        $connected = $false
        try {
            $connected = $ConnectionTask.Wait(200)
        }
        catch {
            throw "The startup control pipe failed: $($_.Exception.GetBaseException().Message)"
        }

        if ($connected) { break }

        if ($Process) {
            $Process.Refresh()
            if ($Process.HasExited) {
                $detail = if ($Diagnose) { & $Diagnose } else { '' }
                throw ("The target PowerShell process exited before it connected " +
                       "(exit code {0}).{1}" -f $Process.ExitCode, $(if ($detail) { " $detail" } else { '' }))
            }
        }

        if ($CheckFailure -and [DateTime]::UtcNow -ge $nextFailureCheck) {
            $failure = & $CheckFailure
            if ($failure) { throw "The target session could not start: $failure" }
            $nextFailureCheck = [DateTime]::UtcNow.AddSeconds(1)
        }

        if ([DateTime]::UtcNow -ge $deadline) {
            $detail = if ($Diagnose) { & $Diagnose } else { '' }
            throw ("The target PowerShell process did not report readiness within {0} seconds.{1}" -f
                [Math]::Round($TimeoutMs / 1000), $(if ($detail) { " $detail" } else { '' }))
        }
    }

    if ($ConnectionTask.IsFaulted) {
        $inner = $ConnectionTask.Exception.GetBaseException()
        throw "The startup control pipe failed: $($inner.Message)"
    }

    $reader = [System.IO.StreamReader]::new(
        $ControlPipe, [System.Text.UTF8Encoding]::new($false), $true, 1024, $true)
    try {
        $readTask = $reader.ReadLineAsync()
        $readTimeout = [Math]::Max(1000, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        try {
            $readCompleted = $readTask.Wait($readTimeout)
        }
        catch {
            throw "The target PowerShell process failed while reporting readiness: $($_.Exception.GetBaseException().Message)"
        }
        if (-not $readCompleted) {
            throw "The target PowerShell process connected but did not report readiness in time."
        }
        $line = $readTask.Result
    }
    finally {
        $reader.Dispose()
    }

    if ($null -eq $line) {
        throw 'The target PowerShell process closed the startup pipe without reporting readiness.'
    }

    if ($line -match '^OK (?<pid>\d+)(?: (?<mode>Custom|Default))?$') {
        $connectionMode = if ($Matches['mode']) { $Matches['mode'] } else { 'Custom' }
        return [pscustomobject]@{
            ProcessId      = [int]$Matches['pid']
            ConnectionMode = $connectionMode
        }
    }
    if ($line -match '^ERROR (?<message>.*)$') {
        throw "The target PowerShell process could not start the session: $($Matches['message'])"
    }

    throw "Unexpected startup message from the target PowerShell process: $line"
}

function New-PSLocalSessionPSSession {
    <#  .SYNOPSIS Wraps a remote runspace in a PSSession.

        PSSession.Create is public from PowerShell 7.3. On 7.1/7.2, use the internal
        PSSession(RemoteRunspace) constructor and add the result to the current
        RunspaceRepository so Get-PSSession still sees it. #>
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.Runspace]$Runspace,
        [string]$TransportName,
        [Parameter(Mandatory)][System.Management.Automation.PSCmdlet]$Cmdlet
    )

    $create = [System.Management.Automation.Runspaces.PSSession].GetMethod(
        'Create',
        [System.Reflection.BindingFlags]'Static,Public',
        $null,
        [type[]]@(
            [System.Management.Automation.Runspaces.Runspace],
            [string],
            [System.Management.Automation.PSCmdlet]),
        $null)
    if ($create) {
        return $create.Invoke($null, @($Runspace, $TransportName, $Cmdlet))
    }

    $ctor = [System.Management.Automation.Runspaces.PSSession].GetConstructor(
        [System.Reflection.BindingFlags]'Instance,NonPublic',
        $null,
        [type[]]@($Runspace.GetType()),
        $null)
    if (-not $ctor) {
        throw 'This PowerShell version does not expose a usable PSSession constructor.'
    }
    $session = $ctor.Invoke(@($Runspace))

    $property = $null
    $type = $Cmdlet.GetType()
    while ($type -and -not $property) {
        $property = $type.GetProperty(
            'RunspaceRepository',
            [System.Reflection.BindingFlags]'Instance,Public,NonPublic')
        $type = $type.BaseType
    }
    if ($property) {
        $repository = $property.GetValue($Cmdlet)
        if ($repository) {
            $add = $repository.GetType().GetMethod(
                'Add',
                [System.Reflection.BindingFlags]'Instance,Public')
            if ($add) {
                $null = $add.Invoke($repository, @($session))
            }
        }
    }

    return $session
}

#endregion


#region Public cmdlets

function New-LocalPSSession {
    <#
    .SYNOPSIS
        Starts a PowerShell process as another local user and returns a PSSession to it.

    .DESCRIPTION
        New-LocalPSSession is a "su" for PowerShell. It launches a Windows PowerShell 5.1
        or PowerShell 7.1+ target under the requested account, exposes a local named pipe
        with an ACL for only that account and the caller, connects with
        NamedPipeConnectionInfo, and wraps the resulting remote runspace in a normal
        PSSession.

        The session process exits automatically when the PSSession is removed or the
        calling PowerShell process goes away.

        The launch method is selected automatically:
          - -CurrentUser      starts the target PowerShell directly.
          - -Identity         uses a temporary scheduled task with a service-account
                              logon; the caller must be elevated or LocalSystem.
          - elevated caller   uses a temporary scheduled task (batch logon).
          - non-elevated      uses CreateProcessWithLogonW (interactive logon).

    .PARAMETER Credential
        Credentials for the account that the session should run as.

    .PARAMETER Identity
        Runs the target as a built-in passwordless account: NT AUTHORITY\SYSTEM,
        NT AUTHORITY\LOCAL SERVICE, or NT AUTHORITY\NETWORK SERVICE. Task Scheduler is the
        only route to these accounts, so the caller must be elevated (or LocalSystem).
        Use -Credential for an account with a password.

    .PARAMETER CurrentUser
        Starts a session as the current user. Intended for diagnostics and testing.

    .PARAMETER Name
        A friendly name for the returned PSSession.

    .PARAMETER NoProfile
        Starts the target PowerShell with -NoProfile.

    .PARAMETER PowerShellPath
        The target executable to run. Defaults to the current installation
        ($PSHOME\pwsh.exe on 7.1+, $PSHOME\powershell.exe on 5.1). The target account must
        be able to read and execute this file. The target edition may differ from the
        caller's edition.

    .PARAMETER RunLevel
        Requested task run level: Highest (default) or Limited. It applies to the temporary
        scheduled task used for -Identity or an elevated caller with -Credential. Highest
        falls back to Limited when the caller cannot create a highest-privilege task. The
        non-elevated interactive path inherits the target account's logon token instead.

    .PARAMETER StartupTimeoutSeconds
        How long to wait for the target process to start listening. Defaults to 30.

    .EXAMPLE
        $cred = Get-Credential 'CONTOSO\alice'
        $session = New-LocalPSSession -Credential $cred -Name Alice
        Invoke-Command -Session $session -ScriptBlock { whoami }
        Remove-PSSession -Session $session

    .EXAMPLE
        $session = New-LocalPSSession -CurrentUser -NoProfile
        Invoke-Command -Session $session -ScriptBlock { $PID }
        Remove-PSSession -Session $session

    .EXAMPLE
        # From an elevated PowerShell
        $session = New-LocalPSSession -Identity 'NT AUTHORITY\SYSTEM' -NoProfile
        Invoke-Command -Session $session -ScriptBlock { whoami }
        Remove-PSSession -Session $session
    #>
    [CmdletBinding(DefaultParameterSetName = 'Credential')]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Credential', Position = 0)]
        [ValidateNotNull()]
        [pscredential]$Credential,

        [Parameter(Mandatory, ParameterSetName = 'Identity')]
        [ValidateNotNullOrEmpty()]
        [string]$Identity,

        [Parameter(Mandatory, ParameterSetName = 'CurrentUser')]
        [switch]$CurrentUser,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$Name,

        [Parameter()]
        [switch]$NoProfile,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]$PowerShellPath,

        [Parameter()]
        [ValidateSet('Highest', 'Limited')]
        [string]$RunLevel = 'Highest',

        [Parameter()]
        [ValidateRange(5, 300)]
        [int]$StartupTimeoutSeconds = 30
    )

    $callerIsDesktop = $PSVersionTable.PSEdition -eq 'Desktop'
    if ($callerIsDesktop) {
        if ($PSVersionTable.PSVersion -lt [version]'5.1') {
            throw 'New-LocalPSSession requires Windows PowerShell 5.1 or later.'
        }
    }
    else {
        if ($PSVersionTable.PSVersion -lt [version]'7.1') {
            throw 'New-LocalPSSession requires PowerShell 7.1 or later.'
        }
        if (-not $IsWindows) {
            throw 'New-LocalPSSession uses Windows named pipes and Windows logon APIs; it is Windows-only.'
        }
    }

    $callerIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $callerSid = $callerIdentity.User

    $passwordlessLaunch = $false
    if ($PSCmdlet.ParameterSetName -eq 'CurrentUser') {
        # The token already carries the answer; do not depend on name resolution here.
        $target = [pscustomobject]@{
            UserName      = $callerIdentity.Name
            Sid           = $callerIdentity.User
            IsCurrentUser = $true
        }
        $launchMethod = 'CurrentUser'
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'Identity') {
        # Validate the account before the elevation check so an ordinary account gets the
        # useful "use -Credential" message even from a non-elevated caller.
        $target = Resolve-PSLocalSessionBuiltInIdentity -Identity $Identity
        if (-not (Test-PSLocalSessionElevated)) {
            throw ('Built-in service account sessions require an elevated caller or ' +
                   'LocalSystem. Run New-LocalPSSession from an elevated PowerShell.')
        }
        $passwordlessLaunch = $true
        $launchMethod = 'ScheduledTask'
    }
    else {
        $target = Resolve-PSLocalSessionUser -UserName $Credential.UserName
        if (Test-PSLocalSessionElevated) {
            $launchMethod = 'ScheduledTask'
        }
        else {
            $launchMethod = 'CreateProcessWithLogon'
        }
    }

    Write-Verbose ("Creating a local PSSession as '{0}' ({1}) via {2}." -f
        $target.UserName, $target.Sid.Value, $launchMethod)

    $pwshPath = Get-PSLocalSessionPowerShellPath -Path $PowerShellPath
    $moduleDirectory = Split-Path -Parent $script:BootstrapScriptPath
    foreach ($supportFile in $script:BootstrapSupportFiles) {
        $bootstrapFile = Join-Path $moduleDirectory $supportFile
        if (-not (Test-Path -LiteralPath $bootstrapFile -PathType Leaf)) {
            throw ("The bootstrap file '{0}' is missing from the module installation." -f
                $bootstrapFile)
        }
    }

    $pipeName = 'PSLocalSession.{0}' -f [guid]::NewGuid().ToString('N')
    $controlPipeName = 'PSLocalSession.Ctl.{0}' -f [guid]::NewGuid().ToString('N')
    $connectTimeoutSeconds = [Math]::Max($script:BootstrapConnectTimeoutSeconds, $StartupTimeoutSeconds + 30)
    $bootstrapArguments = @(New-PSLocalSessionBootstrapArguments -PipeName $pipeName `
        -ControlPipeName $controlPipeName -CallerSid $callerSid.Value `
        -ConnectTimeoutSeconds $connectTimeoutSeconds -CallerIsDesktop $callerIsDesktop)

    $bootstrapScriptPath = $script:BootstrapScriptPath
    $bootstrapStagingPath = $null
    if (-not $target.IsCurrentUser) {
        if (Test-PSLocalSessionPathUnderProfile -Path $bootstrapScriptPath) {
            Write-Verbose 'The module is under the caller profile; staging a copy.'
            $bootstrapStagingPath = Copy-PSLocalSessionBootstrapFiles `
                -CallerSid $callerSid -TargetSid $target.Sid
            $bootstrapScriptPath = Join-Path $bootstrapStagingPath 'PSLocalSession.Bootstrap.ps1'
        }
        elseif (Test-PSLocalSessionTargetCanRead -BootstrapScriptPath $bootstrapScriptPath `
                -TargetSid $target.Sid) {
            Write-Verbose 'The target can read the module bootstrap; using it directly.'
        }
        else {
            Write-Verbose 'The target cannot read the module bootstrap; staging a copy.'
            $bootstrapStagingPath = Copy-PSLocalSessionBootstrapFiles `
                -CallerSid $callerSid -TargetSid $target.Sid
            $bootstrapScriptPath = Join-Path $bootstrapStagingPath 'PSLocalSession.Bootstrap.ps1'
        }
    }

    $controlPipe = $null
    $connectionTask = $null
    $process = $null
    $task = $null
    $runspace = $null
    $session = $null
    $targetProcessId = 0
    $checkFailure = $null
    $success = $false

    try {
        $controlPipe = New-PSLocalSessionControlPipe -PipeName $controlPipeName `
            -CallerSid $callerSid -TargetSid $target.Sid
        $connectionTask = $controlPipe.WaitForConnectionAsync()

        if ($launchMethod -eq 'ScheduledTask') {
            $taskParameters = @{
                PowerShellPath       = $pwshPath
                BootstrapScriptPath  = $bootstrapScriptPath
                BootstrapArguments   = $bootstrapArguments
                TargetUserName       = $target.UserName
                RunLevel             = $RunLevel
                NoProfile            = $NoProfile
            }
            if ($passwordlessLaunch) {
                $taskParameters['Passwordless'] = $true
            }
            else {
                $taskParameters['Credential'] = $Credential
            }
            $task = Start-PSLocalSessionScheduledTask @taskParameters

            $taskName = $task.TaskName
            $taskPath = $task.TaskPath
            $bootstrapHint = "Ensure the target account can read '$bootstrapScriptPath'."
            $diagnose = {
                $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                if (-not $info) { return 'The session task vanished after it was started.' }
                $hint = Get-PSLocalSessionTaskResultHint -Code $info.LastTaskResult
                $text = 'Task last result: 0x{0:X8}' -f $info.LastTaskResult
                if ($hint) { $text += " -- $hint" }
                if ($info.LastRunTime) { $text += " (last run $($info.LastRunTime))" }
                return "$text $bootstrapHint"
            }

            $checkFailure = {
                $scheduledTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                if (-not $scheduledTask) {
                    return "the scheduled task '$taskPath$taskName' disappeared."
                }
                if ($scheduledTask.State -eq 'Running') { return $null }

                $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                if (-not $info) { return $null }
                # Pending/never-run results are not failures; a real logon error is.
                if ($info.LastTaskResult -eq 0 -or
                    $info.LastTaskResult -eq 0x00041300 -or
                    $info.LastTaskResult -eq 0x00041301 -or
                    $info.LastTaskResult -eq 0x00041303) {
                    return $null
                }

                $hint = Get-PSLocalSessionTaskResultHint -Code $info.LastTaskResult
                $text = "task state $($scheduledTask.State), last result 0x{0:X8}" -f $info.LastTaskResult
                if ($hint) { $text += " -- $hint" }
                return "$text $bootstrapHint"
            }
        }
        else {
            $credentialForProcess = if ($launchMethod -eq 'CreateProcessWithLogon') { $Credential } else { $null }
            $process = Start-PSLocalSessionProcess -PowerShellPath $pwshPath `
                -BootstrapScriptPath $bootstrapScriptPath `
                -BootstrapArguments $bootstrapArguments -Credential $credentialForProcess `
                -NoProfile:$NoProfile

            $targetProcess = $process
            $bootstrapHint = "Ensure the target account can read '$bootstrapScriptPath'."
            $diagnose = {
                if ($targetProcess.HasExited) {
                    return "Target process exited with code $($targetProcess.ExitCode). $bootstrapHint"
                }
                return "Target process $($targetProcess.Id) is still running but did not report readiness."
            }
        }

        Write-Verbose 'Waiting for the target PowerShell process to report readiness.'
        $startup = Wait-PSLocalSessionControlMessage -ControlPipe $controlPipe `
            -ConnectionTask $connectionTask -Process $process -Diagnose $diagnose `
            -CheckFailure $checkFailure `
            -TimeoutMs ([Math]::Max(5000, $StartupTimeoutSeconds * 1000))

        $targetProcessId = [int]$startup.ProcessId
        Write-Verbose "Target PowerShell process is PID $targetProcessId; pipe $pipeName is ready."

        # The task only exists to obtain a batch logon. Once the process is running it is
        # independent of Task Scheduler, so remove the definition (and its stored password)
        # immediately.
        if ($task) {
            Unregister-PSLocalSessionScheduledTask -Task $task
        }

        $controlPipe.Dispose()
        $controlPipe = $null

        if ($startup.ConnectionMode -eq 'Default') {
            # 5.1 has no NamedPipeConnectionInfo(string); both sides use the default
            # AppDomain pipe name derived from the target PID.
            $connectionInfo = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new(
                $targetProcessId)
        }
        else {
            $connectionInfo = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new(
                $pipeName)
        }
        $connectionInfo.OpenTimeout = [Math]::Max(5000, $StartupTimeoutSeconds * 1000)
        # Match New-PSSession's construction: pass the caller host and the current
        # type table. Enter-PSSession uses them for the nested prompt and output.
        if (-not $script:RunspaceTypeTable) {
            $script:RunspaceTypeTable = [System.Management.Automation.Runspaces.TypeTable]::LoadDefaultTypeFiles()
        }
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace(
            $connectionInfo, $Host, $script:RunspaceTypeTable)
        try {
            $runspace.Open()
        }
        catch {
            throw ("The target process is running as '{0}', but the session pipe could not be " +
                   "opened: {1}" -f $target.UserName, $_.Exception.Message)
        }

        # Wrap the remote runspace in a PSSession. On 7.3+ this uses the public
        # PSSession.Create; 7.1/7.2 use the internal constructor + repository fallback.
        # Passing $PSCmdlet keeps the session in the normal Get-PSSession repository.
        $session = New-PSLocalSessionPSSession -Runspace $runspace `
            -TransportName 'NamedPipe' -Cmdlet $PSCmdlet
        if ($Name) { $session.Name = $Name }

        $sessionPipeName = if ($startup.ConnectionMode -eq 'Custom') {
            $pipeName
        }
        else {
            '<default IPC pipe>'
        }
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionProcessId', $targetProcessId))
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionUserName', $target.UserName))
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionPipeName', $sessionPipeName))
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionConnectionMode', $startup.ConnectionMode))
        $sessionRunLevel = if ($task) { $task.RunLevel } else { 'Inherited' }
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionRunLevel', $sessionRunLevel))
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionLaunchMethod', $launchMethod))

        # Ownership of the runspace now belongs to the session. The target process exits
        # when the PSSession is removed and the pipe disconnects.
        $runspace = $null
        $success = $true
        return $session
    }
    finally {
        if ($controlPipe) {
            $controlPipe.Dispose()
        }
        if ($bootstrapStagingPath) {
            Remove-Item -LiteralPath $bootstrapStagingPath -Recurse -Force -ErrorAction SilentlyContinue
        }

        if (-not $success) {
            if ($session) {
                Remove-PSSession -Session $session -ErrorAction SilentlyContinue
            }
            if ($runspace) {
                $runspace.Dispose()
            }
            if ($targetProcessId -gt 0) {
                Write-Verbose "Stopping failed target process $targetProcessId."
                Stop-Process -Id $targetProcessId -Force -ErrorAction SilentlyContinue
            }
            elseif ($process -and -not $process.HasExited) {
                Write-Verbose "Stopping failed target process $($process.Id)."
                Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            }
            if ($task) {
                Stop-PSLocalSessionScheduledTask -Task $task
            }
        }
    }
}

#endregion

Export-ModuleMember -Function New-LocalPSSession
