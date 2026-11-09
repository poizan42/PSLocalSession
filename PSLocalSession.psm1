#Requires -Version 7.6

Set-StrictMode -Version Latest

$script:TaskPath = '\PSLocalSession\'
$script:BootstrapConnectTimeoutSeconds = 60
$script:ControlMessageTimeoutMs = 30000

# The C# helper embedded into the target process.
#
# PowerShell's own `pwsh -CustomPipeName` creates the named pipe with a DACL that
# contains the target user (unless that process is elevated) and BUILTIN\Administrators.
# A non-elevated caller that started the target with CreateProcessWithLogonW is neither,
# and the server-side pipe handle was opened without WRITE_DAC, so the DACL cannot be
# adjusted after the fact. Instead, the target creates the pipe itself with an explicit
# DACL, then drives the very same internal PSRP server that `-CustomPipeName` uses.
$script:CSharpSource = @'
using System;
using System.IO;
using System.IO.Pipes;
using System.Management.Automation.Remoting;
using System.Reflection;

namespace PSLocalSession.Server
{
    public static class PipeServer
    {
        private static readonly Type ServerType = typeof(RemoteSessionNamedPipeServer);
        private static readonly ConstructorInfo ServerCtor = ServerType.GetConstructor(
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic,
            null, new[] { typeof(string) }, null);
        private static readonly PropertyInfo StreamProperty = ServerType.GetProperty(
            "Stream", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly FieldInfo StreamField = ServerType.GetField(
            "<Stream>k__BackingField", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly PropertyInfo IsDisposedProperty = ServerType.GetProperty(
            "IsDisposed", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly MethodInfo StartListeningMethod = ServerType.GetMethod(
            "StartListening", BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly Type MediatorType = ServerType.Assembly.GetType(
            "System.Management.Automation.Remoting.Server.NamedPipeProcessMediator");
        private static readonly MethodInfo RunMethod = MediatorType == null ? null : MediatorType.GetMethod(
            "Run", BindingFlags.Static | BindingFlags.Public | BindingFlags.NonPublic);
        private static readonly Action<string, RemoteSessionNamedPipeServer> RunDelegate = CreateRunDelegate();

        private static Action<string, RemoteSessionNamedPipeServer> CreateRunDelegate()
        {
            if (RunMethod == null) { return null; }
            return (Action<string, RemoteSessionNamedPipeServer>)Delegate.CreateDelegate(
                typeof(Action<string, RemoteSessionNamedPipeServer>), RunMethod);
        }

        private static void EnsureAvailable()
        {
            if (ServerCtor == null || StreamProperty == null || StreamField == null ||
                IsDisposedProperty == null || StartListeningMethod == null ||
                RunMethod == null || RunDelegate == null)
            {
                throw new InvalidOperationException(
                    "This PowerShell version does not expose the named-pipe remoting server API " +
                    "PSLocalSession relies on. PowerShell 7.6 is required.");
            }
        }

        public static RemoteSessionNamedPipeServer Start(string pipeName, PipeSecurity security)
        {
            EnsureAvailable();
            if (string.IsNullOrEmpty(pipeName)) { throw new ArgumentException("Pipe name is required.", nameof(pipeName)); }
            if (security == null) { throw new ArgumentNullException(nameof(security)); }

            var server = (RemoteSessionNamedPipeServer)ServerCtor.Invoke(new object[] { pipeName });
            try
            {
                // The constructor already created one pipe with PowerShell's default DACL.
                // Drop it and recreate the same name with the caller-supplied security descriptor.
                var oldStream = (NamedPipeServerStream)StreamProperty.GetValue(server);
                oldStream.Dispose();

                NamedPipeServerStream stream = null;
                Exception lastError = null;
                for (int attempt = 0; attempt < 50; attempt++)
                {
                    try
                    {
                        stream = NamedPipeServerStreamAcl.Create(
                            pipeName,
                            PipeDirection.InOut,
                            1,
                            PipeTransmissionMode.Byte,
                            PipeOptions.Asynchronous | PipeOptions.FirstPipeInstance,
                            32768,
                            32768,
                            security);
                        break;
                    }
                    catch (IOException e)
                    {
                        // The previous instance can take a moment to disappear from the
                        // object namespace after Dispose.
                        lastError = e;
                        System.Threading.Thread.Sleep(50);
                    }
                }

                if (stream == null)
                {
                    throw new IOException("Could not create the session's named pipe.", lastError);
                }

                StreamField.SetValue(server, stream);

                // This is exactly the callback `pwsh -CustomPipeName` installs.
                Action<RemoteSessionNamedPipeServer> clientConnected =
                    s => RunDelegate(string.Empty, s);
                StartListeningMethod.Invoke(server, new object[] { clientConnected });
                return server;
            }
            catch
            {
                try { server.Dispose(); } catch { }
                throw;
            }
        }

        public static bool IsDisposed(RemoteSessionNamedPipeServer server)
        {
            try
            {
                return (bool)IsDisposedProperty.GetValue(server);
            }
            catch
            {
                return true;
            }
        }

        public static bool IsConnected(RemoteSessionNamedPipeServer server)
        {
            try
            {
                var stream = (NamedPipeServerStream)StreamProperty.GetValue(server);
                return stream != null && stream.IsConnected;
            }
            catch
            {
                return false;
            }
        }
    }
}
'@

$script:CSharpBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script:CSharpSource))


#region General helpers

function Test-PSLocalSessionElevated {
    <# .SYNOPSIS Whether the current token is an elevated administrator token. #>
    [OutputType([bool])]
    [CmdletBinding()]
    param()

    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
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

function Get-PSLocalSessionPowerShellPath {
    <# .SYNOPSIS Locates the pwsh.exe used to host the target session. #>
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

    $candidate = [System.IO.Path]::Combine($PSHOME, 'pwsh.exe')
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw ("Cannot find pwsh.exe at '{0}'. Use -PowerShellPath to point at a shared " +
               "PowerShell 7.6+ installation the target account can read." -f $candidate)
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

function ConvertTo-PSLocalSessionEncodedCommand {
    <# .SYNOPSIS Encodes a script for pwsh -EncodedCommand. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Script
    )

    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
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

    return [System.IO.Pipes.NamedPipeServerStreamAcl]::Create(
        $PipeName,
        [System.IO.Pipes.PipeDirection]::InOut,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous,
        4096,
        4096,
        $security)
}

function New-PSLocalSessionBootstrapScript {
    <# .SYNOPSIS Builds the self-contained script executed inside the target process. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PipeName,
        [Parameter(Mandatory)][string]$ControlPipeName,
        [Parameter(Mandatory)][string]$CallerSid,
        [Parameter(Mandatory)][int]$ConnectTimeoutSeconds
    )

    $template = @'
$ErrorActionPreference = 'Stop'
$pipeName = '__PIPE__'
$controlPipe = '__CONTROL__'
$callerSid = '__CALLER_SID__'
$connectTimeoutSeconds = __CONNECT_TIMEOUT__

function Send-StartupMessage {
    param([string]$Text)

    try {
        $client = [System.IO.Pipes.NamedPipeClientStream]::new(
            '.', $controlPipe, [System.IO.Pipes.PipeDirection]::Out)
        try {
            $client.Connect(10000)
            $writer = [System.IO.StreamWriter]::new($client, [System.Text.UTF8Encoding]::new($false))
            $writer.WriteLine(($Text -replace "`r?`n", ' '))
            $writer.Flush()
            $client.WaitForPipeDrain()
        }
        finally {
            $client.Dispose()
        }
    }
    catch {
        # The caller may already have gone away; there is nowhere useful to report that.
    }
}

try {
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.6') {
        throw 'The target PowerShell must be PowerShell 7.6 or later.'
    }
    if (-not $IsWindows) {
        throw 'The target PowerShell must be running on Windows.'
    }

    $csharp = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CS_B64__'))
    Add-Type -TypeDefinition $csharp -Language CSharp -ErrorAction Stop

    $security = [System.IO.Pipes.PipeSecurity]::new()
    $targetSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    $security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
        $targetSid,
        [System.IO.Pipes.PipeAccessRights]::FullControl,
        [System.Security.AccessControl.AccessControlType]::Allow))

    if ($callerSid -ne $targetSid.Value) {
        $caller = [System.Security.Principal.SecurityIdentifier]::new($callerSid)
        $security.AddAccessRule([System.IO.Pipes.PipeAccessRule]::new(
            $caller,
            [System.IO.Pipes.PipeAccessRights]::FullControl,
            [System.Security.AccessControl.AccessControlType]::Allow))
    }

    $server = [PSLocalSession.Server.PipeServer]::Start($pipeName, $security)
    Send-StartupMessage ('OK {0}' -f $PID)

    $deadline = [DateTime]::UtcNow.AddSeconds($connectTimeoutSeconds)
    while (-not [PSLocalSession.Server.PipeServer]::IsConnected($server) -and
           -not [PSLocalSession.Server.PipeServer]::IsDisposed($server) -and
           [DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }

    if ([PSLocalSession.Server.PipeServer]::IsDisposed($server)) {
        throw 'The named pipe server stopped before a client connected.'
    }
    if (-not [PSLocalSession.Server.PipeServer]::IsConnected($server)) {
        throw "No client connected within $connectTimeoutSeconds seconds."
    }

    # Stay alive while the PSRP client is attached. When the client (or the whole caller
    # process) goes away, the listener disposes the server and the process exits.
    while (-not [PSLocalSession.Server.PipeServer]::IsDisposed($server)) {
        Start-Sleep -Milliseconds 250
    }
}
catch {
    Send-StartupMessage ('ERROR {0}' -f $_.Exception.GetBaseException().Message)
    exit 1
}
'@

    return $template.
        Replace('__CS_B64__', $script:CSharpBase64).
        Replace('__PIPE__', $PipeName).
        Replace('__CONTROL__', $ControlPipeName).
        Replace('__CALLER_SID__', $CallerSid).
        Replace('__CONNECT_TIMEOUT__', [string]$ConnectTimeoutSeconds)
}

#endregion


#region Diagnostics

function Get-PSLocalSessionLogonErrorHint {
    <# .SYNOPSIS Turns a Win32 logon failure into an actionable hint. #>
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Exception]$Exception,
        [Parameter(Mandatory)][ValidateSet('Batch', 'Interactive')][string]$LogonPath
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
        0x8004130F { return 'no account information could be found; the stored credential did not take' }
        0x80070005 { return 'access denied' }
        0x80070569 { return "the account lacks the 'Log on as a batch job' right (or is explicitly denied it)" }
        0x8007052E { return 'the user name or password is incorrect' }
        0x80070532 { return "the account's password has expired" }
        0x80070533 { return 'the account is disabled' }
        0x800704DD { return 'the account is not logged on; the task needs a stored password' }
        0x80070775 { return 'the account is locked out' }
        default { return $null }
    }
}

#endregion


#region Launching the target

function Start-PSLocalSessionProcess {
    <#  .SYNOPSIS Starts pwsh.exe directly, optionally as another user via
        CreateProcessWithLogonW.

        The bootstrap is delivered on standard input: pwsh runs a short command that
        reads all of stdin and invokes it as a script block. CreateProcessWithLogonW
        documents a 1024-character command line limit, and the self-contained bootstrap
        is much longer than that. Standard input has no such limit and needs no shared
        script file. #>
    [OutputType([System.Diagnostics.Process])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$BootstrapScript,
        [pscredential]$Credential,
        [switch]$NoProfile
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $PowerShellPath
    [void]$startInfo.ArgumentList.Add('-NoLogo')
    [void]$startInfo.ArgumentList.Add('-NonInteractive')
    if ($NoProfile) { [void]$startInfo.ArgumentList.Add('-NoProfile') }
    [void]$startInfo.ArgumentList.Add('-Command')
    [void]$startInfo.ArgumentList.Add('[ScriptBlock]::Create([Console]::In.ReadToEnd()).Invoke()')

    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.WorkingDirectory = [System.IO.Path]::Combine($env:SystemRoot, 'System32')
    $startInfo.RedirectStandardInput = $true

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
        $process.StandardInput.Write($BootstrapScript)
        $process.StandardInput.Close()
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

function Start-PSLocalSessionScheduledTask {
    <#  .SYNOPSIS Starts pwsh.exe through Task Scheduler.

        The production path uses a stored password and therefore a BATCH logon. The
        -InteractiveToken switch exists so tests can exercise the task plumbing without a
        second account's password; it registers the task with an interactive-logon
        principal instead. #>
    [OutputType([hashtable])]
    [CmdletBinding(DefaultParameterSetName = 'Password')]
    param(
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$EncodedCommand,
        [Parameter(Mandatory, ParameterSetName = 'Password')][pscredential]$Credential,
        [Parameter(Mandatory)][string]$TargetUserName,
        [Parameter(Mandatory, ParameterSetName = 'Interactive')][switch]$InteractiveToken,
        [switch]$NoProfile
    )

    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw "The ScheduledTasks module is not available; the elevated path cannot start a batch-logon process."
    }

    Remove-OrphanedPSLocalSessionTask

    $taskName = 'session-{0}' -f [guid]::NewGuid().ToString('N')
    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.Add('-NoLogo')
    $arguments.Add('-NonInteractive')
    if ($NoProfile) { $arguments.Add('-NoProfile') }
    $arguments.Add('-EncodedCommand')
    $arguments.Add($EncodedCommand)
    $argumentLine = ConvertTo-PSLocalSessionCommandLine -ArgumentList $arguments.ToArray()

    $action = New-ScheduledTaskAction -Execute $PowerShellPath -Argument $argumentLine `
        -WorkingDirectory ([System.IO.Path]::Combine($env:SystemRoot, 'System32'))
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit (New-TimeSpan -Days 1)
    $task = @{ TaskName = $taskName; TaskPath = $script:TaskPath; Registered = $false }

    $password = $null
    try {
        if ($PSCmdlet.ParameterSetName -eq 'Interactive') {
            $principal = New-ScheduledTaskPrincipal -UserId $TargetUserName `
                -LogonType Interactive -RunLevel Limited
            $null = Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath `
                -Action $action -Settings $settings -Principal $principal `
                -Force -ErrorAction Stop
        }
        else {
            $password = $Credential.GetNetworkCredential().Password
            $null = Register-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath `
                -Action $action -Settings $settings -User $TargetUserName -Password $password `
                -RunLevel Limited -Force -ErrorAction Stop
        }
        $task.Registered = $true
        Start-ScheduledTask -TaskName $taskName -TaskPath $script:TaskPath -ErrorAction Stop
    }
    catch {
        $hint = Get-PSLocalSessionLogonErrorHint -Exception $_.Exception -LogonPath 'Batch'
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
        Write-Warning ("The session is running, but its scheduled task '{1}' at '{0}' could not be " +
            "unregistered: {2} It still holds the stored credential. Remove it with: " +
            "Unregister-ScheduledTask -TaskName '{1}' -TaskPath '{0}' -Confirm:`$false" -f
            $Task.TaskPath, $Task.TaskName, $_.Exception.Message)
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

    if ($line -match '^OK (?<pid>\d+)$') {
        return [pscustomobject]@{ ProcessId = [int]$Matches['pid'] }
    }
    if ($line -match '^ERROR (?<message>.*)$') {
        throw "The target PowerShell process could not start the session: $($Matches['message'])"
    }

    throw "Unexpected startup message from the target PowerShell process: $line"
}

#endregion


#region Public cmdlets

function New-LocalPSSession {
    <#
    .SYNOPSIS
        Starts a PowerShell process as another local user and returns a PSSession to it.

    .DESCRIPTION
        New-LocalPSSession is a "su" for PowerShell. It launches pwsh.exe under the
        requested account, exposes a local named pipe with an ACL for only that account
        and the caller, connects with NamedPipeConnectionInfo, and wraps the resulting
        remote runspace in a normal PSSession.

        The session process exits automatically when the PSSession is removed or the
        calling PowerShell process goes away.

        The launch method is selected automatically:
          - -CurrentUser      starts pwsh.exe directly.
          - elevated caller   uses a temporary scheduled task (batch logon).
          - non-elevated      uses CreateProcessWithLogonW (interactive logon).

    .PARAMETER Credential
        Credentials for the account that the session should run as.

    .PARAMETER CurrentUser
        Starts a session as the current user. Intended for diagnostics and testing.

    .PARAMETER Name
        A friendly name for the returned PSSession.

    .PARAMETER NoProfile
        Starts the target PowerShell with -NoProfile.

    .PARAMETER PowerShellPath
        The pwsh.exe to run. Defaults to the current installation ($PSHOME\pwsh.exe).
        The target account must be able to read and execute this file.

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
    #>
    [CmdletBinding(DefaultParameterSetName = 'Credential')]
    [OutputType([System.Management.Automation.Runspaces.PSSession])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Credential', Position = 0)]
        [ValidateNotNull()]
        [pscredential]$Credential,

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
        [ValidateRange(5, 300)]
        [int]$StartupTimeoutSeconds = 30
    )

    if (-not $IsWindows) {
        throw 'New-LocalPSSession uses Windows named pipes and Windows logon APIs; it is Windows-only.'
    }
    if ($PSVersionTable.PSEdition -ne 'Core' -or $PSVersionTable.PSVersion -lt [version]'7.6') {
        throw 'New-LocalPSSession requires PowerShell 7.6 or later.'
    }

    $callerIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $callerSid = $callerIdentity.User

    if ($PSCmdlet.ParameterSetName -eq 'CurrentUser') {
        # The token already carries the answer; do not depend on name resolution here.
        $target = [pscustomobject]@{
            UserName      = $callerIdentity.Name
            Sid           = $callerIdentity.User
            IsCurrentUser = $true
        }
        $launchMethod = 'CurrentUser'
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
    $pipeName = 'PSLocalSession.{0}' -f [guid]::NewGuid().ToString('N')
    $controlPipeName = 'PSLocalSession.Ctl.{0}' -f [guid]::NewGuid().ToString('N')
    $connectTimeoutSeconds = [Math]::Max($script:BootstrapConnectTimeoutSeconds, $StartupTimeoutSeconds + 30)

    $bootstrap = New-PSLocalSessionBootstrapScript -PipeName $pipeName `
        -ControlPipeName $controlPipeName -CallerSid $callerSid.Value `
        -ConnectTimeoutSeconds $connectTimeoutSeconds
    $encodedCommand = ConvertTo-PSLocalSessionEncodedCommand -Script $bootstrap

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
            $task = Start-PSLocalSessionScheduledTask -PowerShellPath $pwshPath `
                -EncodedCommand $encodedCommand -Credential $Credential `
                -TargetUserName $target.UserName -NoProfile:$NoProfile

            $taskName = $task.TaskName
            $taskPath = $task.TaskPath
            $diagnose = {
                $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
                if (-not $info) { return 'The session task vanished after it was started.' }
                $hint = Get-PSLocalSessionTaskResultHint -Code $info.LastTaskResult
                $text = 'Task last result: 0x{0:X8}' -f $info.LastTaskResult
                if ($hint) { $text += " -- $hint" }
                if ($info.LastRunTime) { $text += " (last run $($info.LastRunTime))" }
                return $text
            }.GetNewClosure()

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
                return $text
            }.GetNewClosure()
        }
        else {
            $credentialForProcess = if ($launchMethod -eq 'CreateProcessWithLogon') { $Credential } else { $null }
            $process = Start-PSLocalSessionProcess -PowerShellPath $pwshPath `
                -BootstrapScript $bootstrap -Credential $credentialForProcess -NoProfile:$NoProfile

            $targetProcess = $process
            $diagnose = {
                if ($targetProcess.HasExited) {
                    return "Target process exited with code $($targetProcess.ExitCode)."
                }
                return "Target process $($targetProcess.Id) is still running but did not report readiness."
            }.GetNewClosure()
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

        $connectionInfo = [System.Management.Automation.Runspaces.NamedPipeConnectionInfo]::new($pipeName)
        $connectionInfo.OpenTimeout = [Math]::Max(5000, $StartupTimeoutSeconds * 1000)
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($connectionInfo)
        try {
            $runspace.Open()
        }
        catch {
            throw ("The target process is running as '{0}', but the session pipe could not be " +
                   "opened: {1}" -f $target.UserName, $_.Exception.Message)
        }

        # PSSession.Create is public API. Passing $PSCmdlet puts the session in the normal
        # Get-PSSession/Remove-PSSession repository.
        $session = [System.Management.Automation.Runspaces.PSSession]::Create(
            $runspace, $null, $PSCmdlet)
        if ($Name) { $session.Name = $Name }

        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionProcessId', $targetProcessId))
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionUserName', $target.UserName))
        $session.PSObject.Properties.Add([System.Management.Automation.PSNoteProperty]::new(
            'LocalPSSessionPipeName', $pipeName))
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
