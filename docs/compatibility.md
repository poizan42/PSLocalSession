# PowerShell version compatibility

## What the committed module supports

`PSLocalSession.psd1`, the `#Requires` line, the public cmdlet, and the target bootstrap all
enforce **PowerShell 7.6 or later**. As committed, no older caller or target is supported.

## Measured behaviour if the version guards are relaxed

These results were measured on 2026-11-09 with portable release builds on Windows build
26300. Tests used `-CurrentUser`; cross-user authentication was not repeated for every target
version.

### Target `pwsh.exe`

| Target | Result | Required change |
|---|---|---|
| 7.6.9 | **works** | none |
| 7.5.9 | **works** | remove only the target version guard |
| 7.4.22 | **works** | remove only the target version guard |
| 7.3.12 | **works** | remove the target guard; remove `PipeOptions.FirstPipeInstance` and the retry/sleep from the bootstrap C# |
| 7.2.24 | **works** | same as 7.3 |
| 7.1.7 | **works** | same as 7.3, plus pass `System.IO.Pipes.AccessControl.dll` (and `System.IO.Pipes.dll` / `System.Security.AccessControl.dll`) to `Add-Type -ReferencedAssemblies` |
| 7.0.13 | **fails** | `NamedPipeServerStreamAcl` does not exist in .NET Core 3.1; needs a portable `CreateNamedPipeW`/P-Invoke pipe-creation path |
| 6.2.7 | **fails** | same as 7.0; .NET Core 2.1 has no `NamedPipeServerStreamAcl` |
| Windows PowerShell 5.1 | **possible; proof of concept works** | replace the process's default IPC server with an ACL-adjusted clone using the **same default pipe name**, then start the internal `NamedPipeProcessMediator`; the caller uses `NamedPipeConnectionInfo(processId)` (default AppDomain). `RemoteSessionNamedPipeServer`/`NamedPipeProcessMediator` are internal, so the helper must be reflection-only. |

### Caller (the PowerShell session running `New-LocalPSSession`)

| Caller | Result | Required change |
|---|---|---|
| 7.6+ | **works** | none |
| 7.4 / 7.5 / 7.3 | **works** if the manifest and `#Requires` allow it | all required public APIs are present |
| 7.2 / 7.1 | **works with a small fallback** | `PSSession.Create(Runspace, string, PSCmdlet)` is public only in 7.3+; use the internal `PSSession(RemoteRunspace)` constructor and add it to `PSCmdlet.RunspaceRepository` via reflection |
| 7.0 / 6.2 | **needs more work** | no `NamedPipeServerStreamAcl` for the control pipe; needs the same portable named-pipe creation helper; plus the 7.1/7.2 `PSSession` fallback |
| Windows PowerShell 5.1 | **possible; compatibility shim required** | use `NamedPipeConnectionInfo(processId)` and the default IPC pipe name; create the control pipe with the .NET Framework `NamedPipeServerStream` + `PipeSecurity` constructor; use the internal `PSSession(RemoteRunspace)` constructor + repository; replace `ProcessStartInfo.ArgumentList` with `Arguments`; use `$PSVersionTable.PSEdition` instead of `$IsWindows` |

The 7.1/7.2 caller fallback was exercised successfully against both a 7.6.9 and a 7.2.24
target.

## Relevant API history

- `NamedPipeConnectionInfo(string customPipeName)` and the `-CustomPipeName` target switch
  exist from **6.2**. Windows PowerShell 5.1 only has the process-id/app-domain constructors.
- `RemoteSessionNamedPipeServer`, `StartListening`, and
  `NamedPipeProcessMediator.Run(string, RemoteSessionNamedPipeServer)` exist from **6.2**
  (`RemoteSessionNamedPipeServer` and the mediator are internal in 5.1 but have the same
  shape).
- `RunspaceFactory.CreateRunspace(RunspaceConnectionInfo)` accepts `NamedPipeConnectionInfo`
  in 5.1 and all 6.2+ versions.
- `PSSession.Create(Runspace, string, PSCmdlet)` became public in **7.3.0**
  (`Add Custom Remote Connections Feature`, #17011). 6.2–7.2 only expose the internal
  `PSSession(RemoteRunspace)` constructor.
- `NamedPipeServerStreamAcl` is a .NET **5.0+** API, so it exists in PowerShell **7.1+**.
  It is absent in 7.0, 6.2, and 5.1. On 7.1 the related types are type-forwarded and
  `Add-Type` needs explicit references to `System.IO.Pipes.AccessControl.dll`.
- `PipeOptions.FirstPipeInstance` is a .NET **8.0+** API, so it exists in PowerShell
  **7.4+**. It is absent in 7.1–7.3.
- `ProcessStartInfo.ArgumentList` exists from .NET Core 2.1 (PowerShell 6.2+), but not in
  Windows PowerShell 5.1.
- `PipesAclExtensions.SetAccessControl` exists in 6.2/7.0 but fails on an unconnected server
  pipe handle with an unauthorized-operation error; it is not a substitute for creating
  the pipe with the desired DACL.

## Windows PowerShell 5.1: the default IPC server is already a PSRP endpoint

Windows PowerShell 5.1 does have a fully functional named-pipe PSRP **server** and **client**;
they are just internal. A normal `powershell.exe` process is already listening on
`PSHost.<starttime>.<pid>.DefaultAppDomain.<processname>` through
`RemoteSessionNamedPipeServer.IPCNamedPipeServer`.

Proof of concept, run with two Windows PowerShell 5.1 processes:

1. In the target process, reflect `RemoteSessionNamedPipeServer`, set
   `IPCNamedPipeServerEnabled = false`, and dispose `IPCNamedPipeServer` so the default
   listener does not immediately recreate itself.
2. Create a new internal `RemoteSessionNamedPipeServer` with the **same default pipe name**.
   Replace its `_serverPipeStream` field with a `NamedPipeServerStream` created through the
   .NET Framework constructor that takes a `PipeSecurity` (this constructor exists in 5.1).
3. Start the listener with a reflection-created delegate to the internal
   `NamedPipeProcessMediator.Run(string, RemoteSessionNamedPipeServer)` method.
4. In a second Windows PowerShell 5.1 process, connect with
   `[NamedPipeConnectionInfo]::new($targetPid)`, call
   `RunspaceFactory.CreateRunspace($connectionInfo)`, open it, and run a command.

This worked: the client opened the runspace and executed a command in the server process.
No custom PSRP/WinRM server was involved; it is the in-box server.

Important detail: the replacement used the **default AppDomain pipe name**. A custom
AppDomain name / custom pipe name did not complete the PSRP handshake in 5.1, while the
default name did. That is why the 5.1 path should clone the default IPC server rather than
invent a new pipe name.

Remaining work for a full 5.1 port is mechanical: caller-side control pipe ACL, the
`PSSession` fallback, `ProcessStartInfo.Arguments`, `$IsWindows` alternatives, and testing
the cross-user ACL path.

## Suggested path if older versions are required

1. **7.4+ target, 7.3+ caller** — the cheapest useful step: relax the guards, no runtime
   changes.
2. **7.1+ target and caller** — add the 7.1/7.2 `PSSession` fallback, remove
   `FirstPipeInstance`/the retry sleep, and add the 7.1 `Add-Type` references.
3. **7.0/6.2** — replace `NamedPipeServerStreamAcl` with a portable
   `CreateNamedPipeW`/security-descriptor helper in both the target and the caller control
   pipe.
4. **Windows PowerShell 5.1** — viable without a custom PSRP server: clone/replace the
   default IPC server with an ACL-adjusted version using the default pipe name, use the
   process-id connection constructor, and add the caller-side compatibility shim. This is
   a separate port but not a new remoting stack.

Cross-user behavior on older targets has not been tested; the ACL path is independent of
the PSRP version, but a second account is needed to validate it.
