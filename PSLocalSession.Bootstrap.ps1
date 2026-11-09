#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PipeName,
    [Parameter(Mandatory)][string]$ControlPipeName,
    [Parameter(Mandatory)][string]$CallerSid,
    [Parameter(Mandatory)][int]$ConnectTimeoutSeconds,
    [Parameter(Mandatory)][int]$CallerIsDesktop
)

$ErrorActionPreference = 'Stop'
$pipeName = $PipeName
$controlPipe = $ControlPipeName
$callerSid = $CallerSid
$connectTimeoutSeconds = $ConnectTimeoutSeconds
$callerIsDesktop = $CallerIsDesktop -eq 1

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
    $isDesktopTarget = $PSVersionTable.PSEdition -eq 'Desktop'
    if ($isDesktopTarget) {
        if ($PSVersionTable.PSVersion -lt [version]'5.1') {
            throw 'The target PowerShell must be Windows PowerShell 5.1 or later.'
        }
    }
    else {
        if ($PSVersionTable.PSVersion -lt [version]'7.1') {
            throw 'The target PowerShell must be PowerShell 7.1 or later.'
        }
        if (-not $IsWindows) {
            throw 'The target PowerShell must be running on Windows.'
        }
    }

    $csharpFile = if ($isDesktopTarget) {
        'PSLocalSession.PipeServer.Desktop.cs'
    }
    else {
        'PSLocalSession.PipeServer.Core.cs'
    }
    $csharpPath = Join-Path $PSScriptRoot $csharpFile
    if (-not (Test-Path -LiteralPath $csharpPath -PathType Leaf)) {
        throw "The pipe helper '$csharpPath' was not found."
    }

    if ($isDesktopTarget) {
        Add-Type -Path $csharpPath -ErrorAction Stop
    }
    elseif ($PSVersionTable.PSVersion -lt [version]'7.2') {
        # In 7.1 the pipes ACL types are type-forwarded and Add-Type needs the
        # implementations explicitly.
        $referenceAssemblies = @([System.Management.Automation.PSObject].Assembly.Location)
        foreach ($assemblyName in 'System.IO.Pipes.dll',
                                  'System.IO.Pipes.AccessControl.dll',
                                  'System.Security.AccessControl.dll') {
            $assemblyPath = Join-Path $PSHOME $assemblyName
            if (Test-Path -LiteralPath $assemblyPath) {
                $referenceAssemblies += $assemblyPath
            }
        }
        Add-Type -Path $csharpPath -ReferencedAssemblies $referenceAssemblies -ErrorAction Stop
    }
    else {
        Add-Type -Path $csharpPath -ErrorAction Stop
    }

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

    if ($isDesktopTarget -or $callerIsDesktop) {
        # A 5.1 caller cannot use NamedPipeConnectionInfo(string), and a 5.1 target
        # only completed the handshake on its default AppDomain pipe. Use a clone of
        # the default IPC server with the caller/target DACL in either case.
        $server = $null
        $lastError = $null
        for ($attempt = 0; $attempt -lt 50 -and -not $server; $attempt++) {
            try {
                $server = [PSLocalSession.Server.PipeServer]::StartDefault($security)
            }
            catch {
                $lastError = $_
                Start-Sleep -Milliseconds 50
            }
        }
        if (-not $server) { throw $lastError }
        $connectionMode = 'Default'
    }
    else {
        $server = [PSLocalSession.Server.PipeServer]::Start($pipeName, $security)
        $connectionMode = 'Custom'
    }
    Send-StartupMessage ('OK {0} {1}' -f $PID, $connectionMode)

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
